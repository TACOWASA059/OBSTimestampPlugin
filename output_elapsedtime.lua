-- 録画中の経過時間ログ記録と録画停止後のブラウザ経由アップロード・再生するスクリプト --
local obs = obslua
local ffi = require("ffi")
local bit = require("bit")

local start_time = nil -- 録画開始時間
local folder_path = "" -- 出力フォルダを保存する変数
local file_name = "" -- 出力ファイル名
local trigger_key = "" -- トリガーキーを保存する変数
local VK_F5 = 0x01 -- デフォルトの仮想キーコード
local last_trigger_time = 0 -- 最後にキーが押された時間
local cool_down = 2 -- クールタイム（秒）

-- ===== 設定（UIから変更可） =====
local chrome_path   = [[C:\Program Files\Google\Chrome\Application\chrome.exe]]
local user_data_dir = [[C:\temp\chrome_dev]]
local cdp_port      = 9222
local mediaplayer_url    = "https://tacowasa059.github.io/mediaplayer_v2.github.io/"

local open_player_on_stop= true -- 録画停止時にメディアプレイヤーを自動起動

local recent_video_path = ""
local recent_txt_path   = ""
local g_settings = nil
local enable_experimental_features = false
local ignore_first_click = false

-- ===== ログ/ユーティリティ =====
local function log(fmt, ...)  obs.script_log(obs.LOG_INFO,  string.format(fmt, ...)) end
local function warn(fmt, ...) obs.script_log(obs.LOG_WARNING,string.format(fmt, ...)) end
local function err(fmt, ...)  obs.script_log(obs.LOG_ERROR,  string.format(fmt, ...)) end
local function sleep(sec) local t=os.clock()+sec while os.clock()<t do end end
local function json_escape(s) return (s:gsub('[\\"]',{['\\']='\\\\',['"']='\\"'})) end
local function urlencode(s) return (s:gsub("([^%w%-%_%.%~])", function(c) return string.format("%%%02X", string.byte(c)) end)) end

-- ===== UTF-16=======--

-- UTF-8文字列をWindows API用のUTF-16配列に変換する関数
local function W(s)
    local CP_UTF8 = 65001
    local n = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
    local buf = ffi.new("unsigned short[?]", n + 1)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n)
    buf[n] = 0
    return buf
end

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

  local wpath = W(path_utf8)
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

-- UTF-16配列をUTF-8文字列に変換
local function U16to8(buf)
    local CP_UTF8 = 65001
    local needed = ffi.C.WideCharToMultiByte(CP_UTF8, 0, buf, -1, nil, 0, nil, nil)
    if needed > 0 then
        local utf8_buf = ffi.new("char[?]", needed)
        ffi.C.WideCharToMultiByte(CP_UTF8, 0, buf, -1, utf8_buf, needed, nil, nil)
        return ffi.string(utf8_buf)
    end
    return ""
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

local function filetime_to_int64(ft)
    return tonumber(ft.dwHighDateTime) * 4294967296 + tonumber(ft.dwLowDateTime)
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

-- Windows APIを使用してキー名を取得
function get_key_name_text(vk_code)
    local mouse_names = {
        [0x01] = "Mouse Left",
        [0x02] = "Mouse Right",
        [0x04] = "Mouse Middle",
        [0x05] = "Mouse X1",
        [0x06] = "Mouse X2",
    }
    if mouse_names[vk_code] then
        return mouse_names[vk_code]
    end

    local scan_code = ffi.C.MapVirtualKeyW(vk_code, 0)
    local lParam = bit.lshift(scan_code, 16)
    
    if vk_code >= 0x21 and vk_code <= 0x2E then
        lParam = bit.bor(lParam, bit.lshift(1, 24))
    end
    
    local buf_len = 256
    local buf = ffi.new("unsigned short[?]", buf_len)
    local ret = ffi.C.GetKeyNameTextW(lParam, buf, buf_len)
    
    if ret > 0 then
        local CP_UTF8 = 65001
        local needed = ffi.C.WideCharToMultiByte(CP_UTF8, 0, buf, -1, nil, 0, nil, nil)
        if needed > 0 then
            local utf8_buf = ffi.new("char[?]", needed)
            ffi.C.WideCharToMultiByte(CP_UTF8, 0, buf, -1, utf8_buf, needed, nil, nil)
            return ffi.string(utf8_buf)
        end
    end
    return string.format("VK_0x%02X", vk_code)
end

-- キー検出関数
function detect_pressed_key()
    for vk = 0x01, 0xFF do
        if is_key_pressed(vk) then
             return get_key_name_text(vk), vk
        end
    end
    return nil, nil
end

-- 秒をhh:mm:ss形式に変換する
function seconds_to_hms(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local seconds = seconds % 60
    return string.format("[%02d:%02d:%02d] ", hours, minutes, seconds)
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

-- OBSの録画設定パスを取得する関数
function get_obs_recording_path()
    local path = nil
    local profile = obs.obs_frontend_get_profile_config()
    if not profile then return nil end

    -- モード確認 (Simple vs Advanced)
    local output_mode = obs.config_get_string(profile, "Output", "Mode")
    
    if output_mode == "Advanced" then
        path = obs.config_get_string(profile, "AdvOut", "RecFilePath")
        -- RecFilePathが空ならRecDirを見るケースもあるが、基本はRecFilePathかRecDir
        if not path or path == "" then
             path = obs.config_get_string(profile, "AdvOut", "RecDir")
        end
    else
        -- Simple Mode
        path = obs.config_get_string(profile, "SimpleOutput", "FilePath")
    end

    if path and path ~= "" then
        -- パス区切りの正規化
        path = path:gsub("\\", "/")
    end
    
    return path
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


local function touch_access(path, mode)
    if mode == "open" then
        local h = ffi.C.CreateFileW(
            W(path),
            0x80000000,
            1, 
            nil,
            3,
            0,
            nil
        )

        if h ~= ffi.cast("HANDLE", -1) then
            local buf = ffi.new("char[1]")
            local read = ffi.new("DWORD[1]")
            ffi.C.ReadFile(h, buf, 1, read, nil)
            ffi.C.CloseHandle(h)
        end

    elseif mode == "force" then
        local h = ffi.C.CreateFileW(
            W(path),
            0x100,
            0,
            nil,
            3,
            0,
            nil
        )

        if h ~= ffi.cast("HANDLE", -1) then
            local now = os.time() * 10000000 + 116444736000000000
            local ft = ffi.new("FILETIME")
            ft.dwLowDateTime  = now % 4294967296
            ft.dwHighDateTime = math.floor(now / 4294967296)

            ffi.C.SetFileTime(h, nil, ft, nil)
            ffi.C.CloseHandle(h)
        end
    end
end

local function open_mediaplayer(video, txt)
  if not video and not txt then
    warn("動画/テキストが見つかりません")
    return
  end
  if not start_chrome_if_needed() then err("ChromeのCDPポートに接続できません"); return end
  touch_access(video, "force")
  touch_access(txt, "force")

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

local function open_mediaplayer_with_recent()
  local video, txt = get_recent_video_and_saved_txt()
  open_mediaplayer(video, txt)
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

local function is_remux_enabled()
    local profile = obs.obs_frontend_get_profile_config()
    if not profile then return false end
    return obs.config_get_bool(profile, "Video", "AutoRemux")
end

-- ===== 録画停止トリガ =====
local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        start_time = os.time() -- 録画開始時刻を取得

        -- folder_path は script_update で解決済み。もし空なら警告して終了
        if not folder_path or folder_path == "" then
             warn("出力フォルダが設定されていません。")
             file_name = ""
             return
        end

        local out_dir = folder_path
        -- 末尾スラッシュ補正
        if out_dir:sub(-1) ~= "/" and out_dir:sub(-1) ~= "\\" then
            out_dir = out_dir .. "/"
        end

        -- 現在の録画出力からファイル名取得を試みる
        local rec_filename_base = nil
        local output = obs.obs_frontend_get_recording_output()
        if output then
            local settings = obs.obs_output_get_settings(output)
            local path = obs.obs_data_get_string(settings, "path")
            obs.obs_data_release(settings)
            obs.obs_output_release(output)
            
            if path and path ~= "" then
                -- フルパスからファイル名(拡張子あり)を取り出す
                local name = path:match(".*[/\\](.-)$") or path
                -- 拡張子を除く
                rec_filename_base = name:match("^(.*)%.[^.]+$") or name
            end
        end

        if rec_filename_base then
             log("録画ファイル名に合わせて設定: " .. rec_filename_base .. ".txt")
             file_name = out_dir .. rec_filename_base .. ".txt"
        else
            -- 取得できなかった場合はタイムスタンプ
            file_name = out_dir .. recording_start_time_as_filename()
        end

        if file_name ~= "" then
            log("ファイルへの書き込みを開始: " .. file_name)

            local line = "start\n"
            if rec_filename_base then
                line = rec_filename_base .. "\n"
            end
            local ok, werr = write_utf8_append(file_name, line)
            if not ok then
                warn("FFI append failed: " .. tostring(werr) .. " : " .. tostring(file_name))
            end
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
            
            if is_remux_enabled() then
                wait_mp4_async(last)
            else
                if open_player_on_stop then open_mediaplayer_with_recent() end
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

local function filetime_to_int64(ft)
    return tonumber(ft.dwHighDateTime) * 4294967296 + tonumber(ft.dwLowDateTime)
end

local function refresh_recording_list(props)
    local list = obs.obs_properties_get(props, "selected_recording")
    if not list then return end
    obs.obs_property_list_clear(list)

    local rec_path = get_obs_recording_path()
    if not rec_path or rec_path == "" then return end

    local out_dir = folder_path
    if not out_dir or out_dir == "" then return end

    if rec_path:sub(-1) ~= "/" and rec_path:sub(-1) ~= "\\" then
        rec_path = rec_path .. "/"
    end
    if out_dir:sub(-1) ~= "/" and out_dir:sub(-1) ~= "\\" then
        out_dir = out_dir .. "/"
    end

    local find_data = ffi.new("WIN32_FIND_DATAW")
    local hFind = ffi.C.FindFirstFileW(W(rec_path .. "*.mp4"), find_data)
    if hFind == ffi.cast("HANDLE", -1) then return end

    local files = {}

    repeat
        local mp4_name = U16to8(find_data.cFileName)
        if mp4_name ~= "" then
            local write_time = filetime_to_int64(find_data.ftLastWriteTime)
            local access_time = filetime_to_int64(find_data.ftLastAccessTime)

            -- NEW 判定
            local is_new = (write_time == access_time)

            -- txt チェック
            local txt_name = mp4_name:gsub("%.mp4$", ".txt")
            local txt_full_path = out_dir .. txt_name
            local has_txt = file_exists_utf8(txt_full_path)

            table.insert(files, {
                name = mp4_name,
                time = write_time,
                has_txt = has_txt,
                is_new = is_new
            })
        end
    until ffi.C.FindNextFileW(hFind, find_data) == 0

    ffi.C.FindClose(hFind)

    table.sort(files, function(a, b)
        return a.time > b.time
    end)

    for _, f in ipairs(files) do
        local label = f.name
        if f.has_txt then
            label = "📝 " .. label
        end
        if f.is_new then
            label = "🔥 " .. label
        end

        obs.obs_property_list_add_string(list, label, f.name)
    end

    if #files > 0 then
        obs.obs_data_set_string(
            g_settings,
            "selected_recording",
            files[1].name
        )
    end
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

    -- トリガーキー設定セクション
    obs.obs_properties_add_text(props, "label_key_detect", "\n=== トリガーキー設定 ===", obs.OBS_TEXT_INFO)
    
    -- 現在のトリガーキーを表示
    obs.obs_properties_add_text(props, "current_trigger_key", "現在のトリガーキー: 【" .. (trigger_key ~= "" and trigger_key or "未設定") .. "】", obs.OBS_TEXT_INFO)
    
    -- キー検出ボタン
    obs.obs_properties_add_button(props, "detect_key_button", "キー検出開始", function(props, p)
        key_detection_mode = true
        detected_key_name = ""
        ignore_first_click = true
        log("キー検出モード開始: 任意のキーを押してください")
        
        -- 現在のトリガーキー表示を更新
        local p_current = obs.obs_properties_get(props, "current_trigger_key")
        obs.obs_property_set_description(p_current, "現在のトリガーキー: 検出中... (キーを押して[更新]を押してください)")
        
        return true
    end)
    
    -- 手動更新ボタン
    obs.obs_properties_add_button(props, "refresh_button", "更新", function(props, p)
        -- 現在の検出キー名を再取得して表示更新
        local p_current = obs.obs_properties_get(props, "current_trigger_key")
        local text = "現在のトリガーキー: 【" .. (trigger_key ~= "" and trigger_key or "未設定") .. "】"
        if key_detection_mode then
             text = "現在のトリガーキー: 検出中... (キーを押して[更新]を押してください)"
        end
        obs.obs_property_set_description(p_current, text)
        return true -- ここでtrueを返すことで画面リフレッシュ
    end)
    obs.obs_properties_add_text(props, "trigger_key_setting_info", "[トリガーキーの設定方法]\n1. [キー検出開始]を押す\n2. 設定したいトリガーキーを押す\n3. [更新]を押す", obs.OBS_TEXT_INFO)
    

    -- 最近使用したファイル（ユーザーが手動で差し替えられるように Path 入力にする）
    obs.obs_properties_add_text(props, "label_recent", "\n\n=== 最近使用したファイル ===", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_text(props, "label_info0", "録画完了してから押すと更新されます", obs.OBS_TEXT_INFO)
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

    obs.obs_properties_add_text(props, "label_experiment", "\n\n=== 実験的機能 ===", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_text(props, "label_info1", "Chromeを用いてメモツールを開く\n以下の実行にはChrome必須", obs.OBS_TEXT_INFO)

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
    obs.obs_properties_add_text(props, "label_file_selection1", "\n最近使用したファイル(動画ファイルとTXTファイル)", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_button(props,"btn_open_player","最近使用したファイルでメディアプレーヤーを起動",function()
      open_mediaplayer_with_recent(); return true
    end)

    -- ファイル選択機能
    obs.obs_properties_add_text(props, "label_file_selection2", "\n過去録画ファイル選択\n📝: txtファイルあり\n🔥: 未視聴", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_list(props, "selected_recording", "対象ファイル", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    
    obs.obs_properties_add_button(props, "btn_refresh_recordings", "リストを更新", function(props, p)
        refresh_recording_list(props)
        return true
    end)

    obs.obs_properties_add_button(props, "btn_open_selected", "過去の録画ファイルでメディアプレーヤーを起動", function(props, p)
        local selected = obs.obs_data_get_string(g_settings, "selected_recording")
        if selected == "" then
            warn("ファイルが選択されていません。")
            return true
        end
        
        local rec_path = get_obs_recording_path()
        if not rec_path then warn("録画パス取得失敗"); return true end
        if rec_path:sub(-1) ~= "/" and rec_path:sub(-1) ~= "\\" then rec_path = rec_path .. "/" end
        local video_path = rec_path .. selected
        
        local out_dir = folder_path
        if out_dir:sub(-1) ~= "/" and out_dir:sub(-1) ~= "\\" then out_dir = out_dir .. "/" end
        local txt_path = out_dir .. selected:gsub("%.mp4$", ".txt")
        
        open_mediaplayer(video_path, txt_path)
        refresh_recording_list(props)
        return true
    end)

    obs.obs_properties_add_text(props, "label_info2", "\n\nChrome設定(通常は変更不要)", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_path(props,"chrome_path","Chrome 実行ファイル",obs.OBS_PATH_FILE,"chrome.exe;*.exe",chrome_path)
    obs.obs_properties_add_path(props,"user_data_dir","ユーザーデータディレクトリ",obs.OBS_PATH_DIRECTORY,"",user_data_dir)
    obs.obs_properties_add_int(props,"cdp_port","CDPポート",1024,65535,1)

    refresh_recording_list(props)
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
    folder_path = obs.obs_data_get_string(g_settings, "folder_path")
    -- 空ならOBS設定から取得して内部変数にセットし、設定にも反映させる
    if folder_path == "" then
        local obs_rec_path = get_obs_recording_path()
        if obs_rec_path and obs_rec_path ~= "" then
            folder_path = obs_rec_path
            -- UI側(プロパティ)にも値をセットして表示させる
            obs.obs_data_set_string(g_settings, "folder_path", folder_path)
            log("出力パス未設定のため、OBS録画パスをデフォルトとして使用(設定に反映): " .. folder_path)
        end
    end

    chrome_path   = obs.obs_data_get_string(g_settings,"chrome_path")
    user_data_dir = obs.obs_data_get_string(g_settings,"user_data_dir")
    cdp_port      = obs.obs_data_get_int(g_settings,"cdp_port")

    open_player_on_stop = obs.obs_data_get_bool(s,"open_player_on_stop")

    mediaplayer_url = obs.obs_data_get_string(s, "mediaplayer_url")

    enable_experimental_features = obs.obs_data_get_bool(s, "enable_experimental_features")

    -- トリガーキーの設定読み込み(数値コード優先)
    local saved_code = obs.obs_data_get_int(s, "trigger_key_code")
    trigger_key = obs.obs_data_get_string(s, "trigger_key")
    
    if saved_code and saved_code ~= 0 then
        VK_F5 = saved_code
        -- FFIが利用可能で、user32がロードされていれば名前を取得して表示を更新
        if user32 then
             local name = get_key_name_text(saved_code)
             if name then
                 trigger_key = name
                 detected_key_name = name -- UI表示用にも反映
             end
        end
    end

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
        BOOL ReadFile(
            HANDLE hFile,
            void* lpBuffer,
            DWORD nNumberOfBytesToRead,
            DWORD* lpNumberOfBytesRead,
            void* lpOverlapped
        );
        BOOL CloseHandle(HANDLE hObject);

        // キー名取得用
        unsigned int MapVirtualKeyW(unsigned int uCode, unsigned int uMapType);
        int GetKeyNameTextW(long lParam, unsigned short* lpString, int cchSize);
        
        // UTF-16 -> UTF-8
        int WideCharToMultiByte(unsigned int CodePage, unsigned long dwFlags,
                                const unsigned short* lpWideCharStr, int cchWideChar,
                                char* lpMultiByteStr, int cbMultiByte,
                                const char* lpDefaultChar, int* lpUsedDefaultChar);

        // ファイル検索
        HANDLE FindFirstFileW(LPCWSTR lpFileName, LPVOID lpFindFileData);
        BOOL FindNextFileW(HANDLE hFindFile, LPVOID lpFindFileData);
        BOOL FindClose(HANDLE hFindFile);

        typedef struct _WIN32_FIND_DATAW {
            DWORD    dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            DWORD    nFileSizeHigh;
            DWORD    nFileSizeLow;
            DWORD    dwReserved0;
            DWORD    dwReserved1;
            WCHAR    cFileName[260];
            WCHAR    cAlternateFileName[14];
        } WIN32_FIND_DATAW;

        BOOL SetFileTime(
            HANDLE hFile,
            const FILETIME* lpCreationTime,
            const FILETIME* lpLastAccessTime,
            const FILETIME* lpLastWriteTime
        );
    ]]
    if not shell32 then shell32 = ffi.load("shell32") end
    if not user32 then user32 = ffi.load("user32") end

end


-- 毎フレームごとに呼ばれる関数
function script_tick(seconds)
    local current_time = os.time()
    
    -- キー検出モード中の処理
    if key_detection_mode then
        local key_name, vk_code = detect_pressed_key()
        if key_name and vk_code then
            if vk_code == 0x01 and ignore_first_click then
                ignore_first_click = false
                return
            end
            if vk_code == 0xF2 then
                return
            end
            
            detected_key_name = key_name
            trigger_key = key_name
            VK_F5 = vk_code
            key_detection_mode = false
            
            log(string.format("検出: %s = 0x%02X (%d)", key_name, vk_code, vk_code))
            
            -- 設定を保存
            if g_settings then
                obs.obs_data_set_string(g_settings, "trigger_key", trigger_key)
                obs.obs_data_set_string(g_settings, "detected_key_name", detected_key_name)
                obs.obs_data_set_int(g_settings, "trigger_key_code", vk_code) -- キーコードを保存
            end
          
        end
        return
    end

    -- クールタイムが経過しているか確認
    if current_time - last_trigger_time >= cool_down then
        if is_key_pressed(VK_F5) then
            if obs.obs_frontend_recording_active() then
                write_elapsed_time_to_file()
                last_trigger_time = current_time
            end
        end
    end


end
