defmodule HexWeb.API.ReleaseController do
  use HexWeb.Web, :controller

  def create(conn, %{"name" => name, "body" => body}) do
    auth =
      if package = HexWeb.Repo.get_by(Package, name: name) do
        &package_owner?(package, &1)
      else
        fn _ -> true end
      end

    authorized(conn, [], auth, fn user ->
      handle_tarball(conn, package, user, body)
    end)
  end

  def show(conn, %{"name" => name, "version" => version}) do
    if (package = HexWeb.Repo.get_by(Package, name: name)) &&
       (release = HexWeb.Repo.get_by(assoc(package, :releases), version: version)) do
      downloads = HexWeb.ReleaseDownload.release(release) |> HexWeb.Repo.one
      release = %{release | package: package, downloads: downloads}

      release = HexWeb.Repo.preload(release, requirements: Release.requirements(release))

      when_stale(conn, release, fn conn ->
        conn
        |> api_cache(:public)
        |> render(:show, release: release)
      end)
    else
      not_found(conn)
    end
  end

  def delete(conn, %{"name" => name, "version" => version}) do
    if (package = HexWeb.Repo.get_by(Package, name: name)) &&
       (release = HexWeb.Repo.get_by(assoc(package, :releases), version: version)) do

      authorized(conn, [], &package_owner?(package, &1), fn _ ->
        case Release.delete(release) |> HexWeb.Repo.delete do
          {:ok, release} ->
            # TODO: Remove package from database if this was the only release
            revert(name, release)

            conn
            |> api_cache(:private)
            |> send_resp(204, "")
          {:error, changeset} ->
            validation_failed(conn, changeset.errors)
        end
      end)
    else
      not_found(conn)
    end
  end

  defp handle_tarball(conn, package, user, body) do
    # TODO: with special form
    # TODO: Repo.transaction
    case HexWeb.Tar.metadata(body) do
      {:ok, meta, checksum} ->
        package_params = %{"name" => meta["name"], "meta" => meta}
        case create_package(conn, package, package_params) do
          {:ok, package} ->
            create_release(conn, package, user, checksum, meta, body)
          {:error, changeset} ->
            validation_failed(conn, changeset.errors)
        end

      {:error, errors} ->
        validation_failed(conn, %{tar: errors})
    end
  end

  defp create_package(conn, package, params) do
    name = params["name"]
    package = package || HexWeb.Repo.get_by(Package, name: name)

    if package do
      authorized(conn, [], &package_owner?(package, &1), fn _ ->
        Package.update(package, params)
        |> HexWeb.Repo.update
      end)
    else
      authorized(conn, [], fn user ->
        Package.create(user, params)
      end)
    end
  end

  defp create_release(conn, package, user, checksum, meta, body) do
    version = meta["version"]
    release_params = %{"app" => meta["app"], "version" => version,
                       "requirements" => meta["requirements"], "meta" => meta}

    if release = HexWeb.Repo.get_by(assoc(package, :releases), version: version) do
      update(conn, package, release, release_params, checksum, user, body)
    else
      create(conn, package, release_params, checksum, user, body)
    end
  end

  defp update(conn, package, release, release_params, checksum, user, body) do
    case Release.update(release, release_params, checksum) do
      {:ok, release} ->
        after_release(package, release.version, user, body)

        release = %{release | package: package}

        conn
        |> api_cache(:public)
        |> render(:show, release: release)
      {:error, errors} ->
        validation_failed(conn, errors)
    end
  end

  defp create(conn, package, release_params, checksum, user, body) do
    case Release.create(package, release_params, checksum) do
      {:ok, release} ->
        after_release(package, release.version, user, body)

        release = %{release | package: package}
        location = release_url(conn, :show, package, release)

        conn
        |> put_resp_header("location", location)
        |> api_cache(:public)
        |> put_status(201)
        |> render(:show, release: release)
      {:error, errors} ->
        validation_failed(conn, errors)
    end
  end

  defp after_release(package, version, user, body) do
    task    = fn -> job(package, version, body) end
    success = fn -> :ok end
    failure = fn reason -> failure(package, version, user, reason) end
    HexWeb.Utils.task(task, success, failure)
  end

  defp job(package, version, body) do
    store = Application.get_env(:hex_web, :store)
    store.put_release("#{package.name}-#{version}.tar", body)
    HexWeb.RegistryBuilder.rebuild
  end

  defp failure(package, version, user, reason) do
    require Logger
    Logger.error "Package upload failed: #{inspect reason}"

    # TODO: Revert database changes

    # TODO: Move to mailer service
    email = Application.get_env(:hex_web, :email)
    body  = Phoenix.View.render(HexWeb.EmailView, "publish_fail.html",
                                layout: {HexWeb.EmailView, "layout.html"},
                                package: package.name,
                                version: version,
                                docs: false)
    title = "Hex.pm - ERROR when publishing #{package.name} v#{version}"
    email.send(user.email, title, body)
  end

  def revert(name, release) do
    task = fn ->
      version = to_string(release.version)
      store   = Application.get_env(:hex_web, :store)

      # Delete release tarball
      store.delete_release("#{name}-#{version}.tar")

      # Delete relevant documentation (if it exists)
      if release.has_docs do
        paths = store.list_docs_pages(Path.join(name, version))
        store.delete_docs("#{name}-#{version}.tar.gz")
        Enum.each(paths, fn path ->
          store.delete_docs_page(path)
        end)
      end

      HexWeb.RegistryBuilder.rebuild
    end

    # TODO: Send mails
    HexWeb.Utils.task(task, fn -> nil end, fn _ -> nil end)
  end
end
