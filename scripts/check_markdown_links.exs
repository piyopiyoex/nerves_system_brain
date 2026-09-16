#!/usr/bin/env elixir

defmodule MarkdownLinkCheck do
  @moduledoc false

  @inline_link_re ~r/!?\[[^\]]*\]\(([^)]+)\)/
  @reference_link_re ~r/^\s{0,3}\[[^\]]+\]:\s*(.+?)\s*$/
  @fence_re ~r/^\s*(`{3,}|~{3,})/

  def run do
    repo_root = Path.expand("..", __DIR__)

    errors =
      repo_root
      |> tracked_markdown_files()
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(&check_file(repo_root, &1))

    case errors do
      [] ->
        0

      errors ->
        IO.puts(:stderr, "Broken Markdown relative links:")
        Enum.each(errors, &IO.puts(:stderr, "  #{&1}"))
        1
    end
  end

  defp tracked_markdown_files(repo_root) do
    {output, 0} = System.cmd("git", ["ls-files", "-z", "--", "*.md"], cd: repo_root)

    output
    |> String.split(<<0>>, trim: true)
    |> Enum.map(&Path.join(repo_root, &1))
  end

  defp check_file(repo_root, markdown_file) do
    markdown_file
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.reduce({[], nil}, fn {raw_line, line_number}, {errors, fence} ->
      line = trim_line_ending(raw_line)

      case Regex.run(@fence_re, line, capture: :all_but_first) do
        [marker] ->
          {errors, update_fence(fence, marker)}

        nil when not is_nil(fence) ->
          {errors, fence}

        nil ->
          line_errors = check_line(repo_root, markdown_file, line_number, line)
          {Enum.reverse(line_errors, errors), nil}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp trim_line_ending(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp update_fence(nil, marker), do: {String.first(marker), String.length(marker)}

  defp update_fence({fence_char, fence_len} = fence, marker) do
    if String.first(marker) == fence_char and String.length(marker) >= fence_len do
      nil
    else
      fence
    end
  end

  defp check_line(repo_root, markdown_file, line_number, line) do
    inline_destinations =
      @inline_link_re
      |> Regex.scan(line, capture: :all_but_first)
      |> Enum.map(&List.first/1)

    reference_destinations =
      case Regex.run(@reference_link_re, line, capture: :all_but_first) do
        [destination] -> [destination]
        nil -> []
      end

    (inline_destinations ++ reference_destinations)
    |> Enum.map(&link_destination/1)
    |> Enum.filter(&relative_file_link?/1)
    |> Enum.flat_map(fn destination ->
      check_destination(repo_root, markdown_file, line_number, destination)
    end)
  end

  defp link_destination(raw) do
    raw = String.trim(raw)

    cond do
      raw == "" ->
        ""

      String.starts_with?(raw, "<") ->
        case :binary.match(raw, ">") do
          {index, 1} -> binary_part(raw, 1, index - 1)
          :nomatch -> raw
        end

      true ->
        case String.split(raw, ~r/\s+/, parts: 2, trim: true) do
          [destination | _] -> destination
          [] -> ""
        end
    end
  end

  defp relative_file_link?(destination) do
    if destination == "" or String.starts_with?(destination, ["#", "/"]) do
      false
    else
      uri = URI.parse(destination)
      is_nil(uri.scheme) and is_nil(uri.host) and uri.path not in [nil, ""]
    end
  end

  defp check_destination(repo_root, markdown_file, line_number, destination) do
    path = destination |> URI.parse() |> Map.fetch!(:path) |> URI.decode()
    target = Path.expand(path, Path.dirname(markdown_file))
    source = Path.relative_to(markdown_file, repo_root)

    cond do
      not inside_repo?(target, repo_root) ->
        ["#{source}:#{line_number}: relative link escapes repository: #{destination}"]

      not File.exists?(target) ->
        ["#{source}:#{line_number}: relative link target not found: #{destination}"]

      true ->
        []
    end
  end

  defp inside_repo?(target, repo_root) do
    target == repo_root or String.starts_with?(target, repo_root <> "/")
  end
end

System.halt(MarkdownLinkCheck.run())
