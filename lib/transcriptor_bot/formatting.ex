defmodule TranscriptorBot.Formatting do
  @moduledoc """
  Converts a plain transcript into Telegram-safe HTML messages.

  Output is always an expandable blockquote. Long transcripts are split on
  sentence boundaries; multipart messages are numbered.
  """

  @telegram_limit 4096
  @quote_open "<blockquote expandable>"
  @quote_close "</blockquote>"
  @content_limit 4_000

  @type render_result :: :empty | {:ok, [String.t()]}

  @spec render(String.t() | nil) :: render_result()
  def render(nil), do: :empty

  def render(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        :empty

      trimmed ->
        parts = chunk(trimmed, @content_limit, &escaped_size/1)
        total = length(parts)

        {:ok,
         parts
         |> Enum.with_index(1)
         |> Enum.map(fn {content, index} -> wrap(content, index, total) end)}
    end
  end

  @doc """
  Splits plain text into chunks no larger than `limit`, preferring sentence and
  paragraph boundaries and never splitting inside a word unless the word itself
  exceeds the limit.
  """
  @spec chunk(String.t(), pos_integer()) :: [String.t()]
  def chunk(text, limit), do: chunk(text, limit, &byte_size/1)

  @spec chunk(String.t(), pos_integer(), (String.t() -> non_neg_integer())) :: [String.t()]
  def chunk(text, limit, measure) when is_binary(text) and is_function(measure, 1) do
    text
    |> String.trim()
    |> sentences()
    |> pack(limit, measure)
  end

  defp sentences(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index()
    |> Enum.flat_map(fn {paragraph, paragraph_index} ->
      paragraph
      |> String.split(~r/(?<=[.!?…])\s+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.with_index()
      |> Enum.map(fn {sentence, sentence_index} ->
        separator =
          cond do
            sentence_index > 0 -> " "
            paragraph_index > 0 -> "\n\n"
            true -> ""
          end

        {separator, sentence}
      end)
    end)
  end

  defp pack([], _limit, _measure), do: []

  defp pack(sentences, limit, measure) do
    {chunks, current} =
      Enum.reduce(sentences, {[], nil}, fn {separator, sentence}, {chunks, current} ->
        cond do
          current != nil and measure.(current <> separator <> sentence) <= limit ->
            {chunks, current <> separator <> sentence}

          measure.(sentence) <= limit ->
            {push(chunks, current), sentence}

          true ->
            {last, leading} = sentence |> split_words(limit, measure) |> List.pop_at(-1)

            chunks =
              Enum.reduce(leading, push(chunks, current), fn piece, acc -> [piece | acc] end)

            {chunks, last}
        end
      end)

    final = push(chunks, current)
    Enum.reverse(final)
  end

  defp push(chunks, nil), do: chunks
  defp push(chunks, current), do: [current | chunks]

  defp split_words(sentence, limit, measure) do
    sentence
    |> String.split(~r/\s+/)
    |> Enum.flat_map(&split_word(&1, limit, measure))
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [] ->
          [word]

        [current | rest] ->
          candidate = current <> " " <> word

          if measure.(candidate) <= limit do
            [candidate | rest]
          else
            [word, current | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp split_word(word, limit, measure) do
    if measure.(word) <= limit do
      [word]
    else
      word
      |> String.graphemes()
      |> Enum.reduce([], fn grapheme, acc ->
        case acc do
          [] ->
            [grapheme]

          [current | rest] ->
            if measure.(current <> grapheme) <= limit do
              [current <> grapheme | rest]
            else
              [grapheme, current | rest]
            end
        end
      end)
      |> Enum.reverse()
    end
  end

  defp wrap(content, 1, 1), do: @quote_open <> escape(content) <> @quote_close

  defp wrap(content, index, total) do
    "(#{index}/#{total})\n" <> @quote_open <> escape(content) <> @quote_close
  end

  defp escaped_size(text), do: text |> escape() |> byte_size()

  @doc "Escapes the characters Telegram HTML mode treats specially."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "Maximum size Telegram accepts for message text."
  def telegram_limit, do: @telegram_limit
end
