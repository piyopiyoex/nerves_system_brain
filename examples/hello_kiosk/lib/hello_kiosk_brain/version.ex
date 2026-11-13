defmodule HelloKioskBrain.Version do
  @moduledoc """
  ファームのバージョン表示用。`mix.exs` の version と、ビルド時の Git コミット(短縮 ID、未コミット変更があれば `+`)。
  Git が無い環境では version のみ。コミットで再コンパイルされるよう `.git/HEAD` と現在ブランチの ref を外部リソースにする。
  """

  @git_dir Path.expand("../../.git", __DIR__)
  @external_resource Path.join(@git_dir, "HEAD")

  # HEAD が "ref: refs/heads/xxx" なら、その ref ファイル(コミットで更新される)も監視する。
  with {:ok, head} <- File.read(Path.join(@git_dir, "HEAD")),
       "ref: " <> ref <- String.trim(head) do
    @external_resource Path.join(@git_dir, ref)
  end

  @version Mix.Project.config()[:version]

  @rev (case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true, cd: Path.dirname(@git_dir)) do
          {out, 0} ->
            dirty =
              case System.cmd("git", ["status", "--porcelain", "--untracked-files=no"], cd: Path.dirname(@git_dir)) do
                {"", 0} -> ""
                {_, 0} -> "+"
                _ -> ""
              end

            String.trim(out) <> dirty

          _ ->
            nil
        end)

  @doc "ホーム画面用の短い文字列(例 \"0.1.0 10fb6f1\")。"
  def short, do: if(@rev, do: "#{@version} #{@rev}", else: @version)

  def version, do: @version
  def rev, do: @rev
end
