defmodule AperDesk.StorageTest do
  use ExUnit.Case, async: true

  alias AperDesk.Storage

  @studio "01a08e79-0000-7000-8000-000000000001"
  @gallery "01a08e79-0000-7000-8000-000000000002"

  describe "key_for/3" do
    test "never uses the name the browser sent" do
      key = Storage.key_for(@studio, @gallery, "../../../etc/passwd.jpg")

      assert key =~ ~r"^studios/#{@studio}/galleries/#{@gallery}/[0-9a-f-]{36}\.jpg$"
      refute key =~ "passwd"
      refute key =~ ".."
    end

    test "keeps a recognised extension and flattens anything else" do
      assert Storage.key_for(@studio, @gallery, "shot.JPEG") =~ ".jpeg"
      assert Storage.key_for(@studio, @gallery, "notes.php") =~ ".bin"
      assert Storage.key_for(@studio, @gallery, "no-extension") =~ ".bin"
    end

    test "two uploads of the same name do not collide" do
      one = Storage.key_for(@studio, @gallery, "IMG_0001.jpg")
      two = Storage.key_for(@studio, @gallery, "IMG_0001.jpg")

      refute one == two
    end
  end

  describe "the local adapter" do
    setup do
      source = Path.join(System.tmp_dir!(), "aperdesk-#{System.unique_integer([:positive])}.jpg")
      File.write!(source, "not really a jpeg")
      on_exit(fn -> File.rm(source) end)
      %{source: source}
    end

    test "round-trips a file and serves it from the public URL", %{source: source} do
      key = Storage.key_for(@studio, @gallery, "IMG_0001.jpg")

      assert {:ok, ^key} = Storage.put(key, source)
      assert File.read!(Path.join("tmp/test_uploads", key)) == "not really a jpeg"
      assert Storage.url(key) == "/uploads/" <> key
    end

    test "refuses to write outside its root" do
      assert {:error, :outside_root} = Storage.put("../escaped.jpg", "whatever")
    end

    test "deleting something already gone is success" do
      assert :ok = Storage.delete("studios/nobody/galleries/nothing/missing.jpg")
    end

    test "a prefix delete takes the whole gallery with it", %{source: source} do
      one = Storage.key_for(@studio, @gallery, "a.jpg")
      two = Storage.key_for(@studio, @gallery, "b.jpg")
      {:ok, _} = Storage.put(one, source)
      {:ok, _} = Storage.put(two, source)

      assert :ok = Storage.delete_prefix(Storage.gallery_prefix(@studio, @gallery))
      refute File.exists?(Path.join("tmp/test_uploads", one))
      refute File.exists?(Path.join("tmp/test_uploads", two))
    end
  end
end
