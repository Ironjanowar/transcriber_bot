defmodule TranscriptorBot.FormattingTest do
  use ExUnit.Case, async: true

  alias TranscriptorBot.Formatting

  describe "render/1" do
    test "returns :empty for blank transcripts" do
      assert :empty = Formatting.render("")
      assert :empty = Formatting.render("   \n\t ")
    end

    test "wraps a short transcript in an expandable HTML blockquote" do
      assert {:ok, [html]} = Formatting.render("Hola mundo.")
      assert html == "<blockquote expandable>Hola mundo.</blockquote>"
    end

    test "escapes HTML special characters" do
      assert {:ok, [html]} = Formatting.render("5 < 6 & 7 > 2")
      assert html == "<blockquote expandable>5 &lt; 6 &amp; 7 &gt; 2</blockquote>"
    end

    test "keeps a single transcript without numbering" do
      assert {:ok, [html]} = Formatting.render(String.duplicate("palabra ", 100))
      refute html =~ "("
    end

    test "splits long text on sentence boundaries and numbers every part" do
      sentence = "Esta es una frase completa que debe conservarse entera. "
      text = String.duplicate(sentence, 200)

      assert {:ok, parts} = Formatting.render(text)
      assert length(parts) > 1

      for {part, index} <- Enum.with_index(parts, 1) do
        assert String.starts_with?(part, "(#{index}/#{length(parts)})\n<blockquote expandable>")
        assert String.ends_with?(part, "</blockquote>")
        assert String.length(part) <= 4096
        assert String.ends_with?(String.trim_trailing(part, "</blockquote>"), ".")
      end
    end

    test "hard-splits a single oversized sentence at word boundaries" do
      text = String.duplicate("palabra ", 2_000)

      assert {:ok, parts} = Formatting.render(text)
      assert length(parts) > 1
      assert Enum.all?(parts, &(String.length(&1) <= 4096))
      assert Enum.all?(parts, &String.contains?(&1, "palabra"))
    end

    test "numbers multipart output and never exceeds Telegram's limit" do
      # Each ampersand expands to five bytes when escaped.
      text = String.duplicate("A & B. ", 900)

      assert {:ok, parts} = Formatting.render(text)
      assert length(parts) > 1
      assert Enum.all?(parts, &(byte_size(&1) <= 4096))
    end

    test "preserves paragraphs" do
      text = "Primer párrafo.\n\nSegundo párrafo."
      assert {:ok, [html]} = Formatting.render(text)
      assert html =~ "Primer párrafo.\n\nSegundo párrafo."
    end

    test "trims surrounding whitespace" do
      assert {:ok, [html]} = Formatting.render("  Hola.  \n")
      assert html == "<blockquote expandable>Hola.</blockquote>"
    end
  end

  describe "chunk/2" do
    test "packs whole sentences greedily" do
      assert ["Uno. Dos.", "Tres."] = Formatting.chunk("Uno. Dos. Tres.", 10)
    end

    test "returns an empty list for blank input" do
      assert [] = Formatting.chunk("   ", 100)
    end
  end
end
