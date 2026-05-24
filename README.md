# ScribbleKV ── Spinel特化・軽量自己完結型インメモリKVS

Spinel（Ruby AOTコンパイラ）専用に構築された軽量自己完結型インメモリKVS（Key-Value Store）です。

Spinelのファイルシステム操作や厳格な静的型推論の制約を克服し、シンプルながらトランザクション制御や入れ子可能なバケットを持ち、クラッシュ耐性を確保しています。

---

## 🚀 主な特徴

1. **行ベース・追記型ログ (Append-Only Log)**
   * すべての書き込み操作はファイル末尾への高速な「追記」で行われ、ディスクI/Oを最小限に抑えます。
2. **アトミック性の保証 (Crash-Survivability)**
   * データの書き込みごとに「コミットマーク (`__TX_COMMIT__`)」と「CRC32チェックサム」を付与。
   * 万が一書き込み中に強制終了（クラッシュや停電）が発生しても、起動時の自動ロードで破損データを検出・破棄し、有効なデータだけでファイルを修復（自己修復機能）します。
3. **データ圧密化 (Compaction)**
   * メモリ上のアクティブな最新データだけを別の一時ファイルにシリアライズし、アトミックに置き換えることで、物理ファイルのサイズ肥大化を防ぎます。
4. **Tombstone方式による安全な削除 (Delete) 機能**
   * 削除操作も追記ログに削除マーカー（Tombstone）を書き込む設計のため、削除処理中のクラッシュに対しても100%の生存性を誇ります。圧密化（Compaction）時に物理ファイルから完全に消去されます。
5. **透過的な入れ子バケット (Nested Buckets)**
   * バケットを階層化してデータを管理できます。Spinelの型推論を壊さない「プレフィックス平坦化ラッパー」方式により、どれだけバケットを入れ子にしてもルートDBと型安全に透過連携します。

---

## 🛠️ 使い方 (Usage)

### 基本的な読み書き
```ruby
require_relative "scribble_kv"

db = ScribbleKV.new("my_data.db")

# データの書き込み (同期的にファイル追記)
db.put("username", "alice")

# データの読み出し (Spinel Hashの仕様上、存在しないキーは空文字列 "" が返ります)
puts db.get("username") # => "alice"
```

### トランザクション
Spinelの型推論エラーを100%回避するため、C言語フレンドリーな明示的トランザクションAPIを使用します。
```ruby
db.begin_transaction
db.put("key1", "value1")
db.put("key2", "value2")
db.commit_transaction # ここで一括してディスクに安全にコミット
```

### 削除 (Delete) とデータ圧密化 (Compaction)
```ruby
# 削除操作 (Tombstoneが追記されます)
db.delete("key1")
puts db.get("key1") # => "" (削除済み)

# 物理ファイルからの削除 & データの圧密化
db.compact 
```

### 入れ子バケット (Nested Buckets)
バケット空間を論理的に分離しつつ、平坦なプレフィックスで透過的にマッピングします。どれだけ深く入れ子にしても、Spinelの多相型エラーは発生しません。
```ruby
# バケットの生成
users = db.bucket("users")
users.put("alice", "active")

# 入れ子バケットの生成 (users/profile/)
profile = users.bucket("profile")
profile.put("theme", "dark")

# 親DBから透過的にアクセス可能
puts db.get("users/alice")         # => "active"
puts db.get("users/profile/theme") # => "dark"

# バケット内のキー一覧取得
p users.keys # => ["alice", "profile/theme"]
```

---

## 📥 ビルドとテストの実行方法

### 動作環境
* Windows (UCRT64 / MinGW 環境)
* MSYS2 gcc
* Spinel コンパイラ

### コンパイル
Spinelを用いてテストスクリプト（`test_scribble_kv.rb`）をビルドします。型推論エラーやコンパイラエラーを一切残さず、クリーンにネイティブバイナリが生成されます。

```bash
$env:MSYS2_PATH_TYPE="inherit"; $env:CHERE_INVOKING=1; $env:MSYSTEM="UCRT64"; C:\Ruby34-x64\msys64\usr\bin\bash.exe -l -c "../spinel/spinel test_scribble_kv.rb -o test_scribble_kv"
```

### テスト実行
```bash
.\test_scribble_kv.exe
```

#### テスト実行結果ログ：
```text
=== ScribbleKV Verification Test ===
1. Testing Basic Put & Get...
  [OK] get('name') should return 'ScribbleKV'
  [OK] get('type') should return 'Pure Ruby KVS'
2. Testing Transactions...
  [OK] get('key1') should return 'value1'
  ...
9. Testing Rollback Feature...
  [OK] db8: value discarded after rollback
  [OK] db9: rolled-back data not written to disk
  [OK] bucket: value discarded after rollback
  [OK] root DB: value discarded after bucket rollback
10. Testing Remove-Rename Crash Recovery...
  [OK] Crash Simulation: 本番ファイルが削除（退避）されていること
  [OK] Crash Simulation: 一時ファイル(.tmp)が残っていること
  [OK] load_db: remove-rename間クラッシュから正常にデータを自己修復してロードできたこと
  [OK] load_db: 本番ファイルが物理的にも自動で修復・復活していること
  [OK] load_db: 一時ファイル(.tmp)はリネームによってクリーンアップされていること
=== All ScribbleKV Tests Passed Successfully! ===
```

---

## 📄 ライセンス

MIT License
