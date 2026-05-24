# scribble_kv.rb
# Spinel特化型超軽量KVS「ScribbleKV」

module LibC
  # 純粋なFFI宣言のみ（競合を避けるためRubyフォールバックは排除）
  ffi_func :rename, [:str, :str], :int
  ffi_func :remove, [:str], :int
end

class ScribbleKV
  # エスケープ処理 (コロン、改行、パーセント記号)
  def self.escape(str)
    # Spinelの型推論器に対して引数が確実にStringであることを示すためのto_s
    s = str.to_s
    s.gsub(/%/, "%25").gsub(/:/, "%3A").gsub(/\n/, "%0A").gsub(/\r/, "%0D")
  end

  def self.unescape(str)
    s = str.to_s
    s.gsub(/%0D/, "\r").gsub(/%0A/, "\n").gsub(/%3A/, ":").gsub(/%25/, "%")
  end

  # テーブルなしの軽量CRC32計算
  def self.crc32(str)
    s = str.to_s
    crc = 0xFFFFFFFF
    i = 0
    len = s.length
    while i < len
      b = s.bytes[i]
      crc ^= b
      j = 0
      while j < 8
        if (crc & 1) != 0
          crc = (crc >> 1) ^ 0xEDB88320
        else
          crc >>= 1
        end
        j += 1
      end
      i += 1
    end
    crc ^ 0xFFFFFFFF
  end

  def initialize(db_path)
    @db_path = db_path.to_s
    
    # 一時ファイルパスを + を使わずに安全に結合してインスタンス変数に固定
    tpath = ""
    tpath << db_path.to_s << ".tmp"
    @tmp_path = tpath.to_s
    
    # 【Spinel型推論ハック】
    # Hashに String -> String のダミーデータを入れておくことで、型を str_str_hash に固定します。
    @data = { "dummy" => "dummy" }
    @tx_buffer = { "dummy" => "dummy" }
    @in_transaction = false
    @tx_log_buffer = []
    
    # データベースのロードと破損リカバリ
    load_db
  end

  # 値の取得
  def get(key)
    @data[key.to_s]
  end

  def [](key)
    get(key)
  end

  # 値の保存 (単一書き込みも1レコードのトランザクションとして扱う)
  def put(key, value)
    if @in_transaction
      @tx_buffer[key.to_s] = value.to_s
    else
      # トランザクション外での単一putは、ブロックを介さずにインラインでトランザクションとして処理する
      # これにより、Spinelのブロック引数やブロック内selfの型推論エラーを100%回避します。
      @tx_buffer = { "dummy" => "dummy" }
      @tx_buffer[key.to_s] = value.to_s
      commit
      @tx_buffer = { "dummy" => "dummy" }
    end
  end

  def []=(key, value)
    put(key, value)
  end

  # --- 明示的トランザクションAPI (Spinelのブロック制限を完全に回避する安全策) ---
  
  def begin_transaction
    if @in_transaction
      raise "Nested transaction not allowed"
    end
    @in_transaction = true
    @tx_buffer = { "dummy" => "dummy" }
  end

  def commit_transaction
    return unless @in_transaction
    commit
    @in_transaction = false
    @tx_buffer = { "dummy" => "dummy" }
  end

  def rollback_transaction
    @in_transaction = false
    @tx_buffer = { "dummy" => "dummy" }
  end

  # 従来のブロック付きトランザクション (明示的APIのラッパー)
  def transaction
    begin_transaction
    begin
      yield
      commit_transaction
    rescue
      rollback_transaction
      raise
    end
  end

  # 全キーの取得
  def keys
    arr = []
    @data.each do |k, v|
      k_str = k.to_s
      v_str = v.to_s
      if k_str != "dummy" && v_str != ""
        arr << k_str
      end
    end
    arr
  end

  # データ圧密化 (メモリ上のアクティブなデータだけでファイルをアトミック再生成)
  def compact
    tmp_path = @tmp_path
    
    # メモリ上の現役データをシリアライズ
    serialized = ""
    @data.each do |k, v|
      # ダミーデータや削除済みデータ(値が"")は書き出さない
      k_str = k.to_s
      v_str = v.to_s
      if k_str != "dummy" && v_str != ""
        escaped_k = ScribbleKV.escape(k_str)
        escaped_v = ScribbleKV.escape(v_str)
        
        # コンパイラのString結合最適化バグを避けるため、+を使わず<<で個別に追記する
        serialized << escaped_k
        serialized << ":"
        serialized << escaped_v
        serialized << "\n"
      end
    end
    
    # Cの string (const char *) と型を整合させるため to_s を呼び出す
    serialized_str = serialized.to_s
    
    # コミットマークとCRC32を計算して付与
    if serialized_str.length > 0
      crc = ScribbleKV.crc32(serialized_str.to_s)
      
      # 分割結合
      commit_line = ""
      commit_line << "__TX_COMMIT__:compact:"
      commit_line << crc.to_s
      commit_line << "\n"
      
      serialized_str << commit_line.to_s
    end
    
    # 一時ファイルに一発書き込み
    File.write(tmp_path, serialized_str.to_s)
    
    # 【Windows/MinGW互換性対策】
    # Windowsの C 標準 rename 関数は、宛先ファイルが既に存在していると上書きできずに失敗します。
    # そのため、リネームの直前に既存の本番ファイルを物理削除します。
    LibC.remove(@db_path)
    LibC.rename(tmp_path, @db_path)
  end

  private

  # トランザクションのコミット処理
  def commit
    # ダミー以外の実データがあるか確認
    has_data = false
    @tx_buffer.each do |k, v|
      if k.to_s != "dummy"
        has_data = true
      end
    end
    return unless has_data
    
    # ログ行の生成
    log_chunk = ""
    @tx_buffer.each do |k, v|
      k_str = k.to_s
      if k_str != "dummy"
        escaped_k = ScribbleKV.escape(k_str)
        escaped_v = ScribbleKV.escape(v.to_s)
        
        # コンパイラのString結合最適化バグを避けるため、+を使わず<<で個別に追記する
        log_chunk << escaped_k
        log_chunk << ":"
        log_chunk << escaped_v
        log_chunk << "\n"
      end
    end
    
    # Cの string (const char *) と型を整合させるため to_s を呼び出す
    log_chunk_str = log_chunk.to_s
    
    # コミットマーク
    crc = ScribbleKV.crc32(log_chunk_str)
    tx_id = "tx"
    
    # 分割結合
    commit_line = ""
    commit_line << "__TX_COMMIT__:"
    commit_line << tx_id
    commit_line << ":"
    commit_line << crc.to_s
    commit_line << "\n"
    
    log_chunk_str = log_chunk_str + commit_line.to_s
    
    # 追記モードでデータベースファイルに書き込み
    File.open(@db_path, "a") do |f|
      f.write(log_chunk_str)
    end
    
    # メモリ上のデータに反映
    @tx_buffer.each do |k, v|
      k_str = k.to_s
      v_str = v.to_s
      if k_str != "dummy"
        if v_str == "__TOMBSTONE__"
          @data[k_str] = ""
        else
          @data[k_str] = v_str
        end
      end
    end
  end

  # 起動時ロードとリカバリ (Spinelの複数Hashコンパイラバグを避けるためのStrArrayバッファ方式)
  def load_db
    tmp_path = ""
    tmp_path << @db_path.to_s << ".tmp"
    tmp_path_str = tmp_path.to_s
    if !File.exist?(@db_path) && File.exist?(tmp_path_str)
      LibC.rename(tmp_path_str, @db_path)
    end
    
    return unless File.exist?(@db_path)
    
    has_corruption = false
    
    # 確定データ
    valid_data = { "dummy" => "dummy" }
    
    # 未確定のログ行を溜める配列 (SpinelのStrArray)
    # [] で初期化すると String 配列として型推論されます
    pending_lines = []
    
    # パース用の結合テキストバッファ
    current_tx_chunk = ""
    
    File.open(@db_path, "r") do |f|
      f.each_line do |line|
        clean_line = line.gsub(/\n/, "").gsub(/\r/, "")
        
        if clean_line.length == 0
          next
        end
        
        if clean_line.start_with?("__TX_COMMIT__:")
          commit_parts = clean_line.split(":")
          if commit_parts.length >= 3
            expected_crc = commit_parts[2].to_i
            actual_crc = ScribbleKV.crc32(current_tx_chunk.to_s)
            
            if expected_crc == actual_crc
              # コミットOK: 溜まっていたペンディング行をすべて確定データに流し込む
              i = 0
              len = pending_lines.length
              while i < len
                pline = pending_lines[i].to_s
                record_parts = pline.split(":")
                if record_parts.length >= 2
                  k = ScribbleKV.unescape(record_parts[0].to_s).to_s
                  v = ScribbleKV.unescape(record_parts[1].to_s).to_s
                  if v == "__TOMBSTONE__"
                    valid_data[k] = ""
                  else
                    valid_data[k] = v
                  end
                end
                i += 1
              end
              
              # バッファをクリア
              pending_lines = []
              current_tx_chunk = ""
            else
              has_corruption = true
              break
            end
          else
            has_corruption = true
            break
          end
        else
          # 通常レコード行: ペンディング配列に溜める
          pending_lines << clean_line.to_s
          current_tx_chunk << line
        end
      end
    end
    
    # コミットされなかった未完了のペンディング行があれば破損と判定
    if pending_lines.length > 0
      has_corruption = true
    end
    
    # ロードできた有効データをメモリにセット
    @data = valid_data
    
    # 破損が検知された場合、有効なデータだけでアトミックにクリーンアップ
    if has_corruption
      compact
    end
  end

  # キーの削除 (Tombstone方式)
  def delete(key)
    k_str = key.to_s
    if @in_transaction
      @tx_buffer[k_str] = "__TOMBSTONE__"
    else
      @tx_buffer = { "dummy" => "dummy" }
      @tx_buffer[k_str] = "__TOMBSTONE__"
      commit
      @tx_buffer = { "dummy" => "dummy" }
    end
  end

  # 入れ子バケットの生成
  def bucket(name)
    Bucket.new(self, name.to_s)
  end

end

# 入れ子構造を平坦なプレフィックスで管理する薄いラッパークラス
class Bucket
  def initialize(db, prefix)
    @db = db
    @prefix = prefix.to_s
  end

  def begin_transaction
    @db.begin_transaction
  end

  def commit_transaction
    @db.commit_transaction
  end

  def rollback_transaction
    @db.rollback_transaction
  end

  def get(key)
    k = ""
    k << @prefix << "/" << key.to_s
    @db.get(k.to_s).to_s
  end

  def [](key)
    get(key).to_s
  end

  def put(key, value)
    k = ""
    k << @prefix << "/" << key.to_s
    @db.put(k.to_s, value.to_s)
  end

  def []=(key, value)
    put(key, value)
  end

  def delete(key)
    k = ""
    k << @prefix << "/" << key.to_s
    @db.delete(k.to_s)
  end

  # 子バケット生成時も、絶対プレフィックスを平坦化してルートのScribbleKVインスタンスを渡す
  # これにより、多相型推論の崩壊を完全に防ぎます
  def bucket(name)
    child_prefix = ""
    child_prefix << @prefix << "/" << name.to_s
    Bucket.new(@db, child_prefix.to_s)
  end

  # インライン化された安全なプレフィックス除去
  def keys
    arr = []
    parent_keys = @db.keys
    i = 0
    len = parent_keys.length
    
    pref = ""
    pref << @prefix << "/"
    pref_len = pref.length
    
    while i < len
      pk = parent_keys[i].to_s
      pk_len = pk.length
      
      # プレフィックス一致確認
      match = true
      if pk_len < pref_len
        match = false
      else
        j = 0
        while j < pref_len
          if pk[j] != pref[j]
            match = false
            break
          end
          j += 1
        end
      end
      
      if match
        sub_k = ""
        j = pref_len
        while j < pk_len
          sub_k << pk[j].to_s
          j += 1
        end
        arr << sub_k.to_s
      end
      
      i += 1
    end
    arr
  end
end
