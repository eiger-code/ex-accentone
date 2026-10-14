defmodule Accentone.ImageTest do
  use ExUnit.Case, async: true

  alias Accentone.Fixtures
  alias Accentone.Image

  # The detection rules, one row per table entry.
  # The classifier (path vs raw bytes), the stat type gate, the size guard, and
  # the MIME-from-bytes rule are all pinned here; the stub-driven consequences
  # (the data URI actually sent) live in the pipeline tests.

  @max 10_000_000

  defp write!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  describe "load/2: the signature table" do
    test "each supported format sniffs to its MIME from the bytes" do
      for {bytes, mime} <- [
            {Fixtures.jpeg(), "image/jpeg"},
            {Fixtures.png(), "image/png"},
            {Fixtures.gif(), "image/gif"},
            {Fixtures.webp(), "image/webp"}
          ] do
        assert {:ok, %{bytes: ^bytes, mime: ^mime}} = Image.load(bytes, @max)
        assert Image.sniff(bytes) == {:ok, mime}
      end
    end

    test "near misses of every signature are :not_an_image" do
      for bytes <- [
            # JPEG is three bytes and its third is part of the signature.
            <<0xFF, 0xD8>>,
            <<0xFF, 0xD8, 0x00>>,
            # PNG needs the full eight bytes.
            <<0x89, "PNG\r\n", 0x1A>>,
            # GIF is four bytes: "GIF8", not "GIF" or "GIF7".
            "GIF",
            "GIF7",
            # WebP needs WEBP at offset 8, after the four-byte RIFF size.
            <<"RIFF", 0, 0, 0, 0, "WEBX">>,
            <<"RIFF", 0, 0, 0, 0>>,
            # Deliberately unsupported: BMP, TIFF, and SVG.
            <<0x42, 0x4D, 0, 0>>,
            <<0x49, 0x49, 0x2A, 0>>,
            "<svg xmlns=\"http://www.w3.org/2000/svg\">"
          ] do
        assert Image.load({:bytes, bytes}, @max) == {:error, :not_an_image}
      end
    end
  end

  describe "load/2: malformed input()" do
    test "anything that is not a binary or a binary-payload tag fails matchably" do
      invalid = [
        123,
        nil,
        :path,
        {:path, 123},
        {:bytes, :nope},
        {:bytes, {:path, "x"}},
        {:foo, "x"},
        {:path, "a", "b"},
        %{},
        ["a"]
      ]

      for bad <- invalid do
        assert Image.load(bad, @max) == {:error, {:invalid_option, :input, bad}}
      end
    end
  end

  describe "load/2: path branch" do
    @tag :tmp_dir
    test "a real file is read, sniffed, and returned for both forms", %{tmp_dir: dir} do
      path = write!(dir, "photo", Fixtures.png())

      assert Image.load(path, @max) == {:ok, %{bytes: Fixtures.png(), mime: "image/png"}}
      assert Image.load({:path, path}, @max) == {:ok, %{bytes: Fixtures.png(), mime: "image/png"}}
    end

    @tag :tmp_dir
    test "the MIME comes from the bytes, never the extension", %{tmp_dir: dir} do
      path = write!(dir, "photo.jpg", Fixtures.png())

      assert {:ok, %{mime: "image/png"}} = Image.load(path, @max)
      assert {:ok, %{mime: "image/png"}} = Image.load({:path, path}, @max)
    end

    @tag :tmp_dir
    test "a non-image file is :not_an_image in both forms", %{tmp_dir: dir} do
      path = write!(dir, "notes.txt", "hello")

      assert Image.load(path, @max) == {:error, :not_an_image}
      assert Image.load({:path, path}, @max) == {:error, :not_an_image}
    end

    test "a missing path is {:enoent, path} in both forms" do
      path = "no/such/accentone-file"

      assert Image.load(path, @max) == {:error, {:enoent, path}}
      assert Image.load({:path, path}, @max) == {:error, {:enoent, path}}
    end

    @tag :tmp_dir
    test "an existing but unreadable file is {:eacces, path}", %{tmp_dir: dir} do
      path = write!(dir, "secret.png", Fixtures.png())
      File.chmod!(path, 0o000)

      # Running as root the OS grants the read and the premise does not hold, so
      # only assert the mapping when the read is actually denied.
      case File.read(path) do
        {:error, :eacces} -> assert Image.load(path, @max) == {:error, {:eacces, path}}
        {:ok, _} -> :ok
      end
    end
  end

  describe "load/2: the stat type gate runs before any read" do
    @tag :tmp_dir
    test "a directory is {:eisdir, path} in both forms", %{tmp_dir: dir} do
      assert Image.load(dir, @max) == {:error, {:eisdir, dir}}
      assert Image.load({:path, dir}, @max) == {:error, {:eisdir, dir}}
    end

    test "/dev/zero is rejected rather than read forever, in both forms" do
      assert Image.load("/dev/zero", @max) == {:error, {:file, :einval, "/dev/zero"}}
      assert Image.load({:path, "/dev/zero"}, @max) == {:error, {:file, :einval, "/dev/zero"}}
    end

    @tag :tmp_dir
    test "a FIFO is rejected rather than blocking, in both forms", %{tmp_dir: dir} do
      path = Path.join(dir, "pipe")
      {_, 0} = System.cmd("mkfifo", [path])

      assert Image.load(path, @max) == {:error, {:file, :einval, path}}
      assert Image.load({:path, path}, @max) == {:error, {:file, :einval, path}}
    end
  end

  describe "load/2: the 4096-byte path rule" do
    test "an over-long valid-UTF-8 argument is a path error, not :not_an_image" do
      path = Fixtures.over_long_path()

      assert Image.load(path, @max) == {:error, {:file, :enametoolong, path}}
      assert Image.load({:path, path}, @max) == {:error, {:file, :enametoolong, path}}
    end

    test "the rule is measured in bytes, not characters" do
      path = Fixtures.over_long_multibyte_path()

      assert String.length(path) < 4096
      assert byte_size(path) > 4096
      assert Image.load(path, @max) == {:error, {:file, :enametoolong, path}}
      assert Image.load({:path, path}, @max) == {:error, {:file, :enametoolong, path}}
    end
  end

  describe "load/2: the ASCII-signature collisions the path-first rule prevents" do
    test "a path whose bytes match GIF8 is read as a file" do
      path = Fixtures.gif_shaped_path()

      # A file error, not :not_an_image: the classifier chose the path branch,
      # and `File.stat/1` then failed on a file that does not exist.
      assert Image.load(path, @max) == {:error, {:enoent, path}}
      # The same bytes under {:bytes, _} are an image — the tag bypasses only the
      # classifier, which is exactly the escape hatch the tag provides.
      assert {:ok, %{mime: "image/gif"}} = Image.load({:bytes, path}, @max)
    end

    test "a path whose bytes match RIFF … WEBP is read as a file" do
      path = Fixtures.webp_shaped_path()

      assert Image.load(path, @max) == {:error, {:enoent, path}}
      assert {:ok, %{mime: "image/webp"}} = Image.load({:bytes, path}, @max)
    end

    test "a NUL-bearing argument is never a path and matches no signature" do
      nul = Fixtures.nul_path()

      assert String.valid?(nul)
      assert Image.load(nul, @max) == {:error, :not_an_image}
    end

    test "a valid-UTF-8 no-signature blob is a path candidate and reports a file error" do
      candidate = "no-such-image.xyz"

      assert Image.load(candidate, @max) == {:error, {:enoent, candidate}}
      assert Image.load({:bytes, candidate}, @max) == {:error, :not_an_image}
    end
  end

  describe "load/2: the size guard" do
    test "an over-limit blob returns its size, not a sniff result" do
      # A valid PNG prefix with junk appended: if sniffing ran first this would
      # succeed, so the size error is what proves the guard comes first.
      bytes = Fixtures.png() <> :binary.copy(<<0>>, 64)
      max = byte_size(Fixtures.png())

      assert Image.load(bytes, max) == {:error, {:image_too_large, byte_size(bytes)}}
      assert Image.load({:bytes, bytes}, max) == {:error, {:image_too_large, byte_size(bytes)}}
    end

    test "bytes exactly at the limit are accepted" do
      bytes = Fixtures.png()

      assert {:ok, %{mime: "image/png"}} = Image.load(bytes, byte_size(bytes))
    end

    @tag :tmp_dir
    test "a regular file's stat size is checked before the read", %{tmp_dir: dir} do
      # Junk that matches no signature, over the limit: reading first would give
      # :not_an_image, so {:image_too_large, 100} proves the stat-size ordering.
      path = write!(dir, "big.bin", :binary.copy(<<0xAB>>, 100))

      assert Image.load(path, 10) == {:error, {:image_too_large, 100}}
      assert Image.load({:path, path}, 10) == {:error, {:image_too_large, 100}}
    end
  end
end
