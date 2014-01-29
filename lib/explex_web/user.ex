defmodule ExplexWeb.User do
  use Ecto.Model

  import Ecto.Query, only: [from: 2]

  queryable "users" do
    field :username, :string
    field :password, :string
    has_many :packages, ExplexWeb.Package
    field :created, :datetime
  end

  validate user,
    username: present()

  def create(username, password) do
    password = String.to_char_list!(password)
    { :ok, salt } = :bcrypt.gen_salt()
    { :ok, hash } = :bcrypt.hashpw(password, salt)
    hash = :erlang.list_to_binary(hash)

    user = ExplexWeb.User.new(username: username, password: hash)
    case validate(user) do
      [] -> { :ok, ExplexWeb.Repo.create(user) }
      errors -> { :error, errors }
    end
  end

  def get(username) do
    from(u in ExplexWeb.User, where: u.username == ^username)
    |> ExplexWeb.Repo.all
    |> List.first
  end

  def auth?(nil, _password), do: false

  def auth?(user, password) do
    stored_hash = user.password
    password = String.to_char_list!(password)
    stored_hash = :erlang.binary_to_list(stored_hash)
    { :ok, hash } = :bcrypt.hashpw(password, stored_hash)
    hash == stored_hash
  end
end