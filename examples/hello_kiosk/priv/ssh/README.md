# priv/ssh — SSH デーモンの鍵

このディレクトリには実機の `:ssh` デーモンが使う鍵を置く。**中身の鍵ファイルは
git 管理外**（秘密鍵と個人の公開鍵のため）。クローン後に自分の環境で生成する。

必要なファイル:

| ファイル | 内容 | git |
|---|---|---|
| `ssh_host_rsa_key` / `.pub` | 実機の SSH ホスト鍵 | 除外 |
| `authorized_keys` | 母艦(開発PC)の公開鍵。これで公開鍵認証ログインする | 除外 |

生成方法（プロジェクトルートで）:

```sh
./scripts/setup_ssh.sh
```

内容は次と等価:

```sh
mkdir -p priv/ssh
ssh-keygen -q -t rsa -b 2048 -m PEM -N "" -f priv/ssh/ssh_host_rsa_key
cp ~/.ssh/id_rsa.pub priv/ssh/authorized_keys   # 母艦の公開鍵を許可
chmod 700 priv/ssh && chmod 600 priv/ssh/ssh_host_rsa_key
```

パスワード認証（user / brain）もフォールバックで有効なので、`authorized_keys`
が無くてもログインは可能。ただし SFTP でのリリース配備を自動化するなら鍵を推奨。
