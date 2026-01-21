-- 録画中の経過時間ログ記録と録画停止後のブラウザ経由アップロード・再生するスクリプト --
local obs = obslua
local ffi = require("ffi")
local bit = require("bit")

local start_time = nil -- 録画開始時間
local folder_path = "" -- 出力フォルダを保存する変数
local file_name = "" -- 出力ファイル名
local trigger_key = "" -- トリガーキーを保存する変数
local VK_F5 = 0x74 -- デフォルトの仮想キーコード
local last_trigger_time = 0 -- 最後にキーが押された時間
local cool_down = 2 -- クールタイム（秒）

-- ===== 設定（UIから変更可） =====
local chrome_path   = [[C:\Program Files\Google\Chrome\Application\chrome.exe]]
local user_data_dir = [[C:\temp\chrome_dev]]
local cdp_port      = 9222
local target_url    = "https://gigafile.nu/"
local mediaplayer_url    = "https://tacowasa059.github.io/mediaplayer_v2.github.io/"

local open_player_on_stop= true -- 録画停止時にメディアプレイヤーを自動起動

local recent_video_path = ""
local recent_txt_path   = ""
local g_settings = nil
local enable_experimental_features = false


-- ===== ログ/ユーティリティ =====
local function log(fmt, ...)  obs.script_log(obs.LOG_INFO,  string.format(fmt, ...)) end
local function warn(fmt, ...) obs.script_log(obs.LOG_WARNING,string.format(fmt, ...)) end
local function err(fmt, ...)  obs.script_log(obs.LOG_ERROR,  string.format(fmt, ...)) end
local function sleep(sec) local t=os.clock()+sec while os.clock()<t do end end
local function json_escape(s) return (s:gsub('[\\"]',{['\\']='\\\\',['"']='\\"'})) end
local function urlencode(s) return (s:gsub("([^%w%-%_%.%~])", function(c) return string.format("%%%02X", string.byte(c)) end)) end

-- ===== UTF-16=======--
-- UTF-8パス対応でテキストをファイル末尾に追記する（WinAPI CreateFileW+WriteFile使用）
local function write_utf8_append(path_utf8, text_utf8)
  local C = ffi.C
  local CP_UTF8 = 65001
  local FILE_APPEND_DATA = 0x00000004
  local FILE_SHARE_READ  = 0x00000001
  local FILE_SHARE_WRITE = 0x00000002
  local OPEN_ALWAYS = 4
  local FILE_ATTRIBUTE_NORMAL = 0x00000080
  local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)

  local function utf8_to_wide(s)
    local n = C.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
    if n == 0 then return nil end
    local buf = ffi.new("WCHAR[?]", n + 1)
    C.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n)
    buf[n] = 0
    return buf
  end

  local wpath = utf8_to_wide(path_utf8)
  if not wpath then return false, "MultiByteToWideChar(path) failed" end

  local h = C.CreateFileW(
    wpath,
    FILE_APPEND_DATA,
    bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE),
    nil,
    OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL,
    nil
  )
  if h == INVALID_HANDLE_VALUE then
    return false, "CreateFileW failed"
  end

  local written = ffi.new("DWORD[1]")
  local ok = C.WriteFile(h, text_utf8, #text_utf8, written, nil) ~= 0
  C.CloseHandle(h)
  if not ok or tonumber(written[0]) ~= #text_utf8 then
    return false, "WriteFile failed"
  end
  return true
end

-- UTF-8文字列をWindows API用のUTF-16配列に変換する関数
local function W(s)
    local CP_UTF8 = 65001
    local n = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
    local buf = ffi.new("unsigned short[?]", n + 1)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n)
    buf[n] = 0
    return buf
end

local function file_exists_utf8(path_utf8)
    local w = W(path_utf8); if not w then return false end
    local a = ffi.C.GetFileAttributesW(w)
    local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
    return a ~= INVALID_FILE_ATTRIBUTES
end

local function get_file_size(path_utf8)
    local w = W(path_utf8); if not w then return nil end
    local data = ffi.new("WIN32_FILE_ATTRIBUTE_DATA[1]")
    local ok = ffi.C.GetFileAttributesExW(w, 0, data) -- GetFileExInfoStandard = 0
    if ok == 0 then return nil end
    local hi = tonumber(data[0].nFileSizeHigh)
    local lo = tonumber(data[0].nFileSizeLow)
    return hi * 4294967296 + lo
end

-- ===== WinHTTP / WebSocket（ffi） =====
ffi.cdef[[
    typedef void* HINTERNET; typedef void* PVOID; typedef unsigned long DWORD; typedef int BOOL;
    typedef const wchar_t* LPCWSTR; typedef unsigned short USHORT; typedef unsigned char BYTE;
    HINTERNET WinHttpOpen(LPCWSTR,DWORD,LPCWSTR,LPCWSTR,DWORD);
    HINTERNET WinHttpConnect(HINTERNET,LPCWSTR,unsigned short,DWORD);
    HINTERNET WinHttpOpenRequest(HINTERNET,LPCWSTR,LPCWSTR,LPCWSTR,LPCWSTR,LPCWSTR*,DWORD);
    BOOL WinHttpSendRequest(HINTERNET,LPCWSTR,DWORD,PVOID,DWORD,DWORD,unsigned long long);
    BOOL WinHttpReceiveResponse(HINTERNET,PVOID);
    BOOL WinHttpReadData(HINTERNET,PVOID,DWORD,DWORD*);
    BOOL WinHttpCloseHandle(HINTERNET);
    BOOL WinHttpSetOption(HINTERNET,DWORD,PVOID,DWORD);
    HINTERNET WinHttpWebSocketCompleteUpgrade(HINTERNET,DWORD);
    DWORD WinHttpWebSocketSend(HINTERNET,int,BYTE*,DWORD);
    DWORD WinHttpWebSocketReceive(HINTERNET,BYTE*,DWORD,DWORD*,int*);
    DWORD WinHttpWebSocketClose(HINTERNET,USHORT,PVOID,DWORD);
]]
local winhttp = ffi.load("winhttp")

local WINHTTP_ACCESS_TYPE_DEFAULT_PROXY=0
local WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET=114
local WINHTTP_WEB_SOCKET_BINARY_MESSAGE   = 0
local WINHTTP_WEB_SOCKET_BINARY_FRAGMENT  = 1
local WINHTTP_WEB_SOCKET_UTF8_MESSAGE     = 2
local WINHTTP_WEB_SOCKET_UTF8_FRAGMENT    = 3
local WINHTTP_WEB_SOCKET_CLOSE            = 4

local function http_get(host,port,path)
    local ses=winhttp.WinHttpOpen(W("OBS-Lua-CDP"),WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,nil,nil,0); if ses==nil then return nil end
    local con=winhttp.WinHttpConnect(ses,W(host),port,0); if con==nil then winhttp.WinHttpCloseHandle(ses); return nil end
    local req=winhttp.WinHttpOpenRequest(con,W("GET"),W(path),nil,nil,nil,0); if req==nil then winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil end
    if winhttp.WinHttpSendRequest(req,nil,0,nil,0,0,0)==0 then winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil end
    if winhttp.WinHttpReceiveResponse(req,nil)==0 then winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil end
    local buf=ffi.new("uint8_t[?]",65536) local out={} local rd=ffi.new("DWORD[1]",0)
    while true do
        if winhttp.WinHttpReadData(req,buf,65536,rd)==0 or rd[0]==0 then break end
        out[#out+1]=ffi.string(buf,rd[0])
    end
    winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses)
    return table.concat(out)
end

local function http_req(method, host, port, path, body, headers)
    local ses=winhttp.WinHttpOpen(W("OBS-Lua-CDP"),WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,nil,nil,0); if ses==nil then return nil end
    local con=winhttp.WinHttpConnect(ses,W(host),port,0); if con==nil then winhttp.WinHttpCloseHandle(ses); return nil end
    local req=winhttp.WinHttpOpenRequest(con,W(method),W(path),nil,nil,nil,0); if req==nil then winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil end
    local hdr=nil; local hdr_len=0
    if headers and #headers>0 then hdr=W(headers); hdr_len=#headers end
    local bptr=nil; local blen=0; local buf
    if body then buf = ffi.new("uint8_t[?]", #body); ffi.copy(buf, body, #body); bptr=ffi.cast("void*",buf); blen=#body end
    if winhttp.WinHttpSendRequest(req, hdr, hdr_len, bptr, blen, blen, 0)==0 then winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil end
    if winhttp.WinHttpReceiveResponse(req, nil)==0 then winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil end
    local rbuf=ffi.new("uint8_t[?]",65536) local out={} local rd=ffi.new("DWORD[1]",0)
    while true do
        if winhttp.WinHttpReadData(req,rbuf,65536,rd)==0 or rd[0]==0 then break end
        out[#out+1]=ffi.string(rbuf,rd[0])
    end
    winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses)
    return table.concat(out)
end

local function ws_connect(host,port,path)
    local ses=winhttp.WinHttpOpen(W("OBS-Lua-CDP"),WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,nil,nil,0); if ses==nil then return nil,"WinHttpOpen" end
    local con=winhttp.WinHttpConnect(ses,W(host),port,0); if con==nil then winhttp.WinHttpCloseHandle(ses); return nil,"WinHttpConnect" end
    local req=winhttp.WinHttpOpenRequest(con,W("GET"),W(path),nil,nil,nil,0); if req==nil then winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil,"OpenRequest" end
    if winhttp.WinHttpSetOption(req,WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,nil,0)==0 then winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil,"UpgradeOpt" end
    if winhttp.WinHttpSendRequest(req,nil,0,nil,0,0,0)==0 then winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil,"SendRequest" end
    if winhttp.WinHttpReceiveResponse(req,nil)==0 then winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil,"ReceiveResponse" end
    local ws=winhttp.WinHttpWebSocketCompleteUpgrade(req,0); if ws==nil then winhttp.WinHttpCloseHandle(req); winhttp.WinHttpCloseHandle(con); winhttp.WinHttpCloseHandle(ses); return nil,"CompleteUpgrade" end
    winhttp.WinHttpCloseHandle(req)
    return {handle=ws,session=ses,connect=con}
end

local function ws_send_text(ws, s)
    local b = ffi.new("uint8_t[?]", #s); ffi.copy(b, s, #s)
    return winhttp.WinHttpWebSocketSend(ws.handle, WINHTTP_WEB_SOCKET_UTF8_MESSAGE, b, #s) == 0
end

local function ws_recv_text(ws, timeout_sec)
    local buf = ffi.new("uint8_t[?]", 65536)
    local len = ffi.new("DWORD[1]")
    local typ = ffi.new("int[1]")
    local t0  = os.clock()
    local chunks = {}

    while true do
        local r = winhttp.WinHttpWebSocketReceive(ws.handle, buf, 65536, len, typ)
        if r ~= 0 then return nil, "recv_error" end

        local t = typ[0]
        if t == WINHTTP_WEB_SOCKET_CLOSE then return nil, "closed" end
        if len[0] > 0 then chunks[#chunks+1] = ffi.string(buf, len[0]) end

        if t == WINHTTP_WEB_SOCKET_UTF8_MESSAGE then
        return table.concat(chunks)
        end
        if timeout_sec and (os.clock() - t0) > timeout_sec then
        return nil, "timeout"
        end
    end
end

local function ws_close(ws)
  winhttp.WinHttpWebSocketClose(ws.handle,1000,nil,0)
  winhttp.WinHttpCloseHandle(ws.handle); winhttp.WinHttpCloseHandle(ws.connect); winhttp.WinHttpCloseHandle(ws.session)
end

-- ===== CDP helpers =====
local next_id = 1
local function cdp_send(ws, method, params_json)
  local id = next_id; next_id = next_id + 1
  local msg = string.format('{"id":%d,"method":"%s","params":%s}', id, method, params_json or "{}")
  if not ws_send_text(ws, msg) then return nil, "send_failed" end
  while true do
    local txt, e = ws_recv_text(ws, 30)
    if not txt then return nil, e or "recv_failed" end
    if txt:find('"id":'..id) then return txt end
  end
end

-- type:"page" の WS だけ採用
local function pick_page_ws(json)
  local ws = json:match([["type"%s*:%s*"page".-"webSocketDebuggerUrl"%s*:%s*"(.-)"]])
  if ws and ws:find("/devtools/page/") then return ws end
  return nil
end

-- ===== Chrome 起動＆待機 =====
local function start_chrome_if_needed()
    local v=http_get("127.0.0.1",cdp_port,"/json/version")
    if v and #v>0 then return true end
    local exp_flag = enable_experimental_features
        and " --enable-experimental-web-platform-features"
        or ""

    local cmd = string.format(
      'cmd /c start "" "%s" --remote-debugging-port=%d --no-first-run --no-default-browser-check --user-data-dir="%s"%s --remote-debugging-address=127.0.0.1',
      chrome_path, cdp_port, user_data_dir, exp_flag
    )

    os.execute(cmd)
    for i=1,15 do sleep(1) v=http_get("127.0.0.1",cdp_port,"/json/version"); if v and #v>0 then return true end end
    return false
end

-- ====== 時間記録用 ======= --

-- キーの押下状態を確認
function is_key_pressed(virtual_key_code)
    local state = ffi.C.GetAsyncKeyState(virtual_key_code)
    return state ~= 0
end

-- 秒をhh:mm:ss形式に変換する
function seconds_to_hms(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local seconds = seconds % 60
    return string.format("%02d:%02d:%02d ", hours, minutes, seconds)
end

-- エクスプローラーで指定フォルダを開く関数
function open_folder_in_explorer(folder)
    if not folder or folder == "" then
        warn("フォルダパスが指定されていません。"); return
    end
    local SW_SHOWNORMAL = 1
    local ret = shell32.ShellExecuteW(nil, W("open"), W(folder), nil, nil, SW_SHOWNORMAL)
    if tonumber(ret) <= 32 then
        warn("ShellExecuteW 失敗: " .. tostring(ret))
    end
end

-- 日付をYYYY-MM-DD_hh-mm-ss形式に変換してファイル名として使用
function recording_start_time_as_filename()
    return os.date("%Y-%m-%d_%H-%M-%S") .. ".txt"
end

-- 録画経過時間をファイルに書き込む
function write_elapsed_time_to_file()
  if start_time == nil or file_name == "" then return end
  local elapsed = os.difftime(os.time(), start_time)
  local line = string.format("%s\n", seconds_to_hms(elapsed))

  local ok, werr = write_utf8_append(file_name, line)
  if not ok then
      warn("FFI append failed: " .. tostring(werr) .. " : " .. tostring(file_name) .. " 出力フォルダが設定されていない可能性があります")
  end
end

----------------------------------------------------------------
-- ====== メディアプレーヤー
----------------------------------------------------------------
local function get_recent_video_and_saved_txt()
  local video = (recent_video_path and recent_video_path ~= "") and recent_video_path or nil
  local txt   = (recent_txt_path   and recent_txt_path   ~= "") and recent_txt_path   or nil
  return video, txt
end


local function open_mediaplayer_with_recent()
  local video, txt = get_recent_video_and_saved_txt()
  if not video and not txt then
    warn("最近使用した動画/テキストが見つかりません")
    return
  end
  if not start_chrome_if_needed() then err("ChromeのCDPポートに接続できません"); return end

  local enc = urlencode(mediaplayer_url)
  local new_json = http_req("PUT","127.0.0.1",cdp_port,"/json/new?"..enc,nil,nil)
  if not new_json or new_json=="" then
    new_json = http_req("PUT","127.0.0.1",cdp_port,"/json/new?url="..enc,nil,nil)
  end

  -- page の WS を優先して拾う
  local ws_url = new_json and pick_page_ws(new_json)
  if not ws_url then
        warn("newでWS取れず。/jsonから既存タブを検索")
        local list_json = http_req("GET","127.0.0.1",cdp_port,"/json",nil,nil)
        if not list_json or list_json=="" then
          err("new/json 取得失敗。Chromeの --remote-debugging-port="..cdp_port.." を確認してね。")
          return
        end
        ws_url = pick_page_ws(list_json)
        if not ws_url then
          err("page ターゲットが見つかりません。/json 応答の一部: "..string.sub(list_json,1,200))
          return
        end
  end

  local path_ws = ws_url:match("ws://127%.0%.0%.1:"..cdp_port.."(.*)") or ws_url:match("ws://localhost:"..cdp_port.."(.*)")
  if not path_ws then err("WSパス抽出失敗: "..tostring(ws_url)); return end

  local ws, ee = ws_connect("127.0.0.1",cdp_port,path_ws); if not ws then err("WS接続失敗: "..(ee or "?")); return end
  if not (cdp_send(ws,"Page.enable") and cdp_send(ws,"Network.enable") and cdp_send(ws,"DOM.enable") and cdp_send(ws,"Runtime.enable")) then
    err("CDP enable失敗"); ws_close(ws); return
  end

  cdp_send(ws, "Page.navigate", string.format('{"url":"%s"}', mediaplayer_url))
  for _=1,100 do
    local r = cdp_send(ws,"Runtime.evaluate",'{"expression":"document.readyState","returnByValue":true}')
    local st = r and r:match([["value"%s*:%s*"([^"]+)"]])
    if st=="complete" or st=="interactive" then break end
    sleep(0.1)
  end

  local doc = cdp_send(ws, "DOM.getDocument", '{"depth":-1,"pierce":true}')
  local rootId = doc and doc:match([["nodeId"%s*:%s*(%d+)]])
  if not rootId then err("root nodeId取得失敗"); ws_close(ws); return end

  local function qsel(selector)
    local q = cdp_send(ws, "DOM.querySelector", string.format('{"nodeId":%s,"selector":%q}', rootId, selector))
    return q and q:match([["nodeId"%s*:%s*(%d+)]])
  end
  local videoNode = qsel("#video-file")
  local annoNode  = qsel("#annotation-file")
  local videoNode2 = qsel("#videoFile")

  if video and videoNode then
    cdp_send(ws, "DOM.setFileInputFiles", string.format('{"nodeId":%s,"files":["%s"]}', videoNode, json_escape(video)))
  end
  if txt and annoNode then
    cdp_send(ws, "DOM.setFileInputFiles", string.format('{"nodeId":%s,"files":["%s"]}', annoNode, json_escape(txt)))
  end

  if videoNode2 then
    if video then
      cdp_send(ws, "DOM.setFileInputFiles", string.format('{"nodeId":%s,"files":["%s"]}', videoNode2, json_escape(video)))
    end
    if txt then
      cdp_send(ws, "DOM.setFileInputFiles", string.format('{"nodeId":%s,"files":["%s"]}', videoNode2, json_escape(txt)))
    end
  end

  ws_close(ws)
end


-- ====== Remux(再多重化) 完了待ち（非同期ポーリング、タイムアウトなし） ======
local remux_watch = nil  -- { mp4_path=..., last_size=nil, stable_count=0, ready_after=... }


local function remux_poll()
  if not remux_watch then
    obs.timer_remove(remux_poll)
    return
  end

  -- 初期0.5s待ち
  if os.clock() < remux_watch.ready_after then
    return
  end

  local sz = get_file_size(remux_watch.mp4_path)
  if not sz then
    -- まだファイルがない
    return
  end

  if remux_watch.last_size and sz == remux_watch.last_size then
    remux_watch.stable_count = remux_watch.stable_count + 1
  else
    remux_watch.stable_count = 0
    remux_watch.last_size = sz
  end

  -- 連続3回（約1.5s）サイズ不変 => 完成とみなす
  if remux_watch.stable_count >= 3 then
    log(string.format("mp4完成を検知: %s", remux_watch.mp4_path))
    obs.timer_remove(remux_poll)
    local target = remux_watch.mp4_path
    recent_video_path = target
    if g_settings then
        script_save(g_settings)
    end
    remux_watch = nil

    if open_player_on_stop then open_mediaplayer_with_recent() end
  end
end

local function wait_mp4_async(original_path)
    local mp4_path = original_path:gsub("%.[^\\/.]+$", ".mp4")
    remux_watch = {
      mp4_path    = mp4_path,
      last_size   = nil,
      stable_count= 0,
      ready_after = os.clock() + 0.5,  -- 初回は0.5s待ち
    }
    obs.timer_add(remux_poll, 500)  -- 500msごとにチェック
end

-- ===== 録画停止トリガ =====
local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        start_time = os.time() -- 録画開始時刻を取得
        file_name = folder_path .. "/" .. recording_start_time_as_filename() -- 録画開始時間をファイル名として使用

        log("ファイルへの書き込みを開始: " .. file_name)

        local line = "start\n"
        local ok, werr = write_utf8_append(file_name, line)
        if not ok then
            warn("FFI append failed: " .. tostring(werr) .. " : " .. tostring(file_name)  .. " 出力フォルダが設定されていない可能性があります")
        end
    end

    if event==obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        log("ファイルへの書き込みを終了: " .. file_name)
        start_time = nil -- 録画停止時にリセット

        local last = obs.obs_frontend_get_last_recording and obs.obs_frontend_get_last_recording()
        if last and last~="" then
            if file_name and file_name ~= "" then
                recent_txt_path = file_name
            end
            recent_video_path = last
            log("録画終了: %s", last)
            
            if last:lower():match("%.mp4$") then
              if open_player_on_stop then open_mediaplayer_with_recent() end

            else
              wait_mp4_async(last)

            end
            if g_settings then
                script_save(g_settings)
            end
        else
            warn("最後の録画ファイルが取得できませんでした")
        end
    end
end

-- ===== OBS スクリプト枠 =====
-- 5) 説明文の改行
function script_description()
    return "選択したキーを押したときに録画経過時間を指定されたフォルダに保存します。"
end

function script_save(settings)
  obs.obs_data_set_string(settings, "recent_video_path", recent_video_path or "")
  obs.obs_data_set_string(settings, "recent_txt_path",   recent_txt_path   or "")
end

function script_properties()
    local props=obs.obs_properties_create()
    -- 出力フォルダを指定するためのテキスト入力フィールドを追加
    obs.obs_properties_add_path(props, "folder_path", "出力フォルダ", obs.OBS_PATH_DIRECTORY, "", nil)

    -- エクスプローラーで開くボタンを追加
    obs.obs_properties_add_button(props, "open_folder_button", "エクスプローラーで開く", function()
        open_folder_in_explorer(folder_path)
    end)

    -- トリガーキーを選択するためのドロップダウンリストを追加
    local p = obs.obs_properties_add_list(props, "trigger_key", "トリガーキー", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    -- ファンクションキー
    for i = 1, 12 do
        obs.obs_property_list_add_string(p, "F" .. tostring(i), "F" .. tostring(i))
    end
    
    -- アルファベットキー
    for i = string.byte("A"), string.byte("Z") do
        local key = string.char(i)
        obs.obs_property_list_add_string(p, key, key)
    end

    -- 数字キー
    for i = 0, 9 do
        obs.obs_property_list_add_string(p, tostring(i), tostring(i))
    end

    -- マウスボタン
    obs.obs_property_list_add_string(p, "Left Mouse Button", "LButton")
    obs.obs_property_list_add_string(p, "Right Mouse Button", "RButton")
    obs.obs_property_list_add_string(p, "Middle Mouse Button", "MButton")
    obs.obs_property_list_add_string(p, "Mouse Side Button 1", "XButton1")
    obs.obs_property_list_add_string(p, "Mouse Side Button 2", "XButton2")

    -- 矢印キー
    obs.obs_property_list_add_string(p, "Up", "Up")
    obs.obs_property_list_add_string(p, "Down", "Down")
    obs.obs_property_list_add_string(p, "Left", "Left")
    obs.obs_property_list_add_string(p, "Right", "Right")

    -- 修飾キー
    obs.obs_property_list_add_string(p, "Space", "Space")
    obs.obs_property_list_add_string(p, "Enter", "Enter")
    obs.obs_property_list_add_string(p, "Escape", "Escape")
    obs.obs_property_list_add_string(p, "Tab", "Tab")
    obs.obs_property_list_add_string(p, "Shift", "Shift")
    obs.obs_property_list_add_string(p, "Ctrl", "Ctrl")
    obs.obs_property_list_add_string(p, "Alt", "Alt")
    obs.obs_property_list_add_string(p, "CapsLock", "CapsLock")
    obs.obs_property_list_add_string(p, "Backspace", "Backspace")

    -- テンキー
    for i = 0, 9 do
        obs.obs_property_list_add_string(p, "Numpad" .. tostring(i), "Numpad" .. tostring(i))
    end
    obs.obs_property_list_add_string(p, "NumpadPlus", "NumpadPlus")
    obs.obs_property_list_add_string(p, "NumpadMinus", "NumpadMinus")
    obs.obs_property_list_add_string(p, "NumpadMultiply", "NumpadMultiply")
    obs.obs_property_list_add_string(p, "NumpadDivide", "NumpadDivide")
    obs.obs_property_list_add_string(p, "NumpadEnter", "NumpadEnter")
    obs.obs_property_list_add_string(p, "NumpadDecimal", "NumpadDecimal")

    -- その他のキー
    obs.obs_property_list_add_string(p, "Insert", "Insert")
    obs.obs_property_list_add_string(p, "Delete", "Delete")
    obs.obs_property_list_add_string(p, "Home", "Home")
    obs.obs_property_list_add_string(p, "End", "End")
    obs.obs_property_list_add_string(p, "PageUp", "PageUp")
    obs.obs_property_list_add_string(p, "PageDown", "PageDown")
    obs.obs_property_list_add_string(p, "PrintScreen", "PrintScreen")
    obs.obs_property_list_add_string(p, "ScrollLock", "ScrollLock")
    obs.obs_property_list_add_string(p, "Pause", "Pause")
    obs.obs_property_list_add_string(p, "NumLock", "NumLock")
    obs.obs_property_list_add_string(p, "ContextMenu", "ContextMenu")

    -- 最近使用したファイル（ユーザーが手動で差し替えられるように Path 入力にする）
    obs.obs_properties_add_text(props, "label_info0", "\n\n録画完了してから押すと更新されます", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_button(props, "reload_button", "最近使用したファイル更新", function()
      return true
    end)
    obs.obs_properties_add_path(props, "recent_video_path", "最近使用した動画ファイル", obs.OBS_PATH_FILE, "動画ファイル (*.mp4;*.mkv;*.mov);;すべて (*.*)", recent_video_path)
    obs.obs_properties_add_button(props, "open_folder_button2_1", "エクスプローラーでフォルダを開く", function()
        open_folder_in_explorer(recent_video_path:match("^(.*)[/\\][^/\\]+$"))
    end)
    obs.obs_properties_add_button(props, "open_folder_button2_2", "ファイルを開く", function()
        open_folder_in_explorer(recent_video_path)
    end)
    obs.obs_properties_add_path(props, "recent_txt_path",   "最近使用したTXTファイル",      obs.OBS_PATH_FILE, "テキスト (*.txt);;すべて (*.*)", recent_txt_path)
        obs.obs_properties_add_button(props, "open_folder_button3_1", "エクスプローラーでフォルダを開く", function()
        open_folder_in_explorer(recent_txt_path:match("^(.*)[/\\][^/\\]+$"))
    end)
    obs.obs_properties_add_button(props, "open_folder_button3_2", "ファイルを開く", function()
        open_folder_in_explorer(recent_txt_path)
    end)

    obs.obs_properties_add_text(props, "label_info1", "\n\n\n以下の実行にはChrome必須\n", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_path(props,"chrome_path","Chrome 実行ファイル",obs.OBS_PATH_FILE,"chrome.exe;*.exe",chrome_path)

    -- 編集可能なドロップダウンリスト
    local url_combo = obs.obs_properties_add_list(
        props,
        "mediaplayer_url",
        "メディアプレーヤーURL",
        obs.OBS_COMBO_TYPE_EDITABLE,
        obs.OBS_COMBO_FORMAT_STRING
    )
    -- プリセットURLを追加
    obs.obs_property_list_add_string(url_combo, "https://tacowasa059.github.io/mediaplayer_v2.github.io/", "https://tacowasa059.github.io/mediaplayer_v2.github.io/")
    obs.obs_property_list_add_string(url_combo, "https://tacowasa059.github.io/mediaplayer.github.io/", "https://tacowasa059.github.io/mediaplayer.github.io/")
    obs.obs_property_list_add_string(url_combo, "https://herusuka.github.io/memo_tool/", "https://herusuka.github.io/memo_tool/")

    obs.obs_properties_add_bool(
        props,
        "enable_experimental_features",
        "Chromeの実験的機能(音声トラック選択用)を有効化"
    )



    obs.obs_properties_add_bool(props,"open_player_on_stop","録画停止時にメディアプレーヤー起動(動画ファイルとTXTファイル)")
    obs.obs_properties_add_button(props,"btn_open_player","最近使用した動画ファイルとTXTでメディアプレーヤーを起動",function()
      open_mediaplayer_with_recent(); return true
    end)

    
    obs.obs_properties_add_path(props,"user_data_dir","ユーザーデータディレクトリ",obs.OBS_PATH_DIRECTORY,"",user_data_dir)
    obs.obs_properties_add_int(props,"cdp_port","CDPポート",1024,65535,1)

    return props
end

function script_defaults(s)
    obs.obs_data_set_default_string(
      s, 
      "chrome_path",
      [[C:\Program Files\Google\Chrome\Application\chrome.exe]]
    )
    obs.obs_data_set_default_string(
      s, 
      "user_data_dir", 
      [[C:\temp\chrome_dev]]
    )
    obs.obs_data_set_default_int(
      s,
      "cdp_port",
      9222
    )
    obs.obs_data_set_default_bool(
      s, 
      "open_player_on_stop",
      false
    )

    obs.obs_data_set_default_string(
      s,
      "mediaplayer_url",
      "https://tacowasa059.github.io/mediaplayer_v2.github.io/"
    )

    obs.obs_data_set_default_bool(
      s,
      "enable_experimental_features",
      false
    )

end

function script_update(s)
    g_settings = s
    chrome_path   = obs.obs_data_get_string(s,"chrome_path")
    user_data_dir = obs.obs_data_get_string(s,"user_data_dir")
    cdp_port      = obs.obs_data_get_int(s,"cdp_port")

    open_player_on_stop = obs.obs_data_get_bool(s,"open_player_on_stop")

    folder_path = obs.obs_data_get_string(s, "folder_path")
    trigger_key = obs.obs_data_get_string(s, "trigger_key")

    mediaplayer_url = obs.obs_data_get_string(s, "mediaplayer_url")

    enable_experimental_features = obs.obs_data_get_bool(s, "enable_experimental_features")


    -- 選択されたキーに基づいて仮想キーコードを設定
    -- キーマッピング
    local key_map = {
        -- ファンクションキー
        F1 = 0x70, F2 = 0x71, F3 = 0x72, F4 = 0x73, F5 = 0x74,
        F6 = 0x75, F7 = 0x76, F8 = 0x77, F9 = 0x78, F10 = 0x79,
        F11 = 0x7A, F12 = 0x7B,

        -- 矢印キー
        Up = 0x26, Down = 0x28, Left = 0x25, Right = 0x27,

        -- 修飾キー
        Space = 0x20, Enter = 0x0D, Escape = 0x1B, Tab = 0x09,
        Shift = 0x10, Ctrl = 0x11, Alt = 0x12, CapsLock = 0x14,
        Backspace = 0x08,

        -- テンキー
        Numpad0 = 0x60, Numpad1 = 0x61, Numpad2 = 0x62, Numpad3 = 0x63,
        Numpad4 = 0x64, Numpad5 = 0x65, Numpad6 = 0x66, Numpad7 = 0x67,
        Numpad8 = 0x68, Numpad9 = 0x69, NumpadPlus = 0x6B,
        NumpadMinus = 0x6D, NumpadMultiply = 0x6A, NumpadDivide = 0x6F,
        NumpadEnter = 0x0D, NumpadDecimal = 0x6E,

        -- その他のキー
        Insert = 0x2D, Delete = 0x2E, Home = 0x24, End = 0x23,
        PageUp = 0x21, PageDown = 0x22, PrintScreen = 0x2C,
        ScrollLock = 0x91, Pause = 0x13, NumLock = 0x90,
        ContextMenu = 0x5D,

        -- マウスボタン
        LButton = 0x01, RButton = 0x02, MButton = 0x04,
        XButton1 = 0x05, XButton2 = 0x06
    }

    -- アルファベットキー
    for i = string.byte("A"), string.byte("Z") do
        local key = string.char(i)
        key_map[key] = i
    end

    -- 数字キー
    for i = 0, 9 do
        key_map[tostring(i)] = 0x30 + i
    end

    VK_F5 = key_map[trigger_key] or 0x74

    -- UI側から手動更新されたときに反映
    local rv = obs.obs_data_get_string(s, "recent_video_path")
    local rt = obs.obs_data_get_string(s, "recent_txt_path")
    if rv ~= "" then recent_video_path = rv end
    if rt ~= "" then recent_txt_path   = rt end
end

-- スクリプトが開始されたときに呼ばれる関数
function script_load(settings)
    g_settings = settings
    recent_video_path = obs.obs_data_get_string(settings, "recent_video_path")
    recent_txt_path   = obs.obs_data_get_string(settings, "recent_txt_path")
    obs.obs_frontend_add_event_callback(on_frontend_event)

    -- Foreign Function Interface
    ffi.cdef[[
        // UTF-8 -> UTF-16
        int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags,
                                const char* lpMultiByteStr, int cbMultiByte,
                                unsigned short* lpWideCharStr, int cchWideChar);

        intptr_t ShellExecuteW(void* hwnd, const unsigned short* lpOperation,
                               const unsigned short* lpFile, const unsigned short* lpParameters,
                               const unsigned short* lpDirectory, int nShowCmd);
        // キー状態
        short GetAsyncKeyState(int vKey);

        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned short WCHAR;
        typedef const WCHAR* LPCWSTR;
        typedef void* LPVOID;
        typedef const void* LPCVOID;

        typedef struct _FILETIME {
            DWORD dwLowDateTime;
            DWORD dwHighDateTime;
        } FILETIME;

        typedef struct _WIN32_FILE_ATTRIBUTE_DATA {
            DWORD    dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            DWORD    nFileSizeHigh;
            DWORD    nFileSizeLow;
        } WIN32_FILE_ATTRIBUTE_DATA;

        int GetFileAttributesExW(const unsigned short* lpFileName, int fInfoLevelId, void* lpFileInformation);

        unsigned long GetFileAttributesW(const unsigned short* lpFileName);

        HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
                        LPVOID lpSecurityAttributes, DWORD dwCreationDisposition,
                        DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);

        BOOL WriteFile(HANDLE hFile, LPCVOID lpBuffer, DWORD nNumberOfBytesToWrite,
                    DWORD* lpNumberOfBytesWritten, LPVOID lpOverlapped);

        BOOL CloseHandle(HANDLE hObject);
    ]]
    if not shell32 then shell32 = ffi.load("shell32") end

end

-- 毎フレームごとに呼ばれる関数
function script_tick(seconds)
    local current_time = os.time()

    -- クールタイムが経過しているか確認
    if current_time - last_trigger_time >= cool_down then
        -- 選択されたキーが押されたときに録画経過時間をファイルに書き込む
        if is_key_pressed(VK_F5) then
            if obs.obs_frontend_recording_active() then
                write_elapsed_time_to_file()
                last_trigger_time = current_time -- 最後にキーが押された時間を更新
            end
        end
    end


end
