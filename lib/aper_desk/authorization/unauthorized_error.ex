defmodule AperDesk.Authorization.UnauthorizedError do
  @moduledoc "Raised when a scope attempts something its role does not permit."
  defexception [:message]
end
