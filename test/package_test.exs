defmodule Accentone.PackageTest do
  use ExUnit.Case, async: true

  # The published package is assembled from two lists in `mix.exs` that have to
  # agree: `package: files:` decides what is in the Hex tarball, and `docs:
  # extras:` decides what HexDocs renders — out of that same tarball. A file that
  # is one and not the other fails at `mix hex.publish`, or worse, at the HexDocs
  # build after it, which is late to find out. Both halves are asserted here
  # instead, for every extra rather than only today's.
  test "every ExDoc extra is a shipped file that exists" do
    config = Mix.Project.config()
    files = config[:package][:files]

    for extra <- config[:docs][:extras],
        file = extra_file(extra),
        is_binary(file) do
      assert file in files, "#{file} is an ExDoc extra but is not in `package: files:`"
      assert File.exists?(file), "#{file} is an ExDoc extra but does not exist"
    end
  end

  defp extra_file(extra) when is_binary(extra), do: extra
  defp extra_file({file, _opts}), do: file
  defp extra_file(_other), do: nil
end
