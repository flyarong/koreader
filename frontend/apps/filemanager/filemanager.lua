local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DeviceListener = require("device/devicelistener")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local Event = require("ui/event")
local FileChooser = require("ui/widget/filechooser")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local FileManagerConverter = require("apps/filemanager/filemanagerconverter")
local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local FileManagerShortcuts = require("apps/filemanager/filemanagershortcuts")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconButton = require("ui/widget/iconbutton")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local PluginLoader = require("pluginloader")
local ReadCollection = require("readcollection")
local ReaderDeviceStatus = require("apps/reader/modules/readerdevicestatus")
local ReaderDictionary = require("apps/reader/modules/readerdictionary")
local ReaderUI = require("apps/reader/readerui")
local ReaderWikipedia = require("apps/reader/modules/readerwikipedia")
local Screenshoter = require("ui/widget/screenshoter")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local BaseUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local C_ = _.pgettext
local Screen = Device.screen
local T = BaseUtil.template

local FileManager = InputContainer:extend{
    title = _("KOReader"),
    root_path = lfs.currentdir(),
    onExit = function() end,

    mv_bin = Device:isAndroid() and "/system/bin/mv" or "/bin/mv",
    cp_bin = Device:isAndroid() and "/system/bin/cp" or "/bin/cp",
    mkdir_bin =  Device:isAndroid() and "/system/bin/mkdir" or "/bin/mkdir",
}

function FileManager:onSetRotationMode(rotation)
    if rotation ~= nil and rotation ~= Screen:getRotationMode() then
        Screen:setRotationMode(rotation)
        if self.instance then
            self:reinit(self.instance.path, self.instance.focused_file)
            UIManager:setDirty(self.instance.banner, function()
                return "ui", self.instance.banner.dimen
            end)
        end
    end
    return true
end

-- init should be set to True when starting the FM for the first time
-- (not coming from the reader). This allows the default to be properly set.
function FileManager:setRotationMode(init)
    local locked = G_reader_settings:isTrue("lock_rotation")
    local rotation_mode = G_reader_settings:readSetting("fm_rotation_mode") or Screen.ORIENTATION_PORTRAIT
    -- Only enforce the default rotation on first FM open, or when switching to the FM when sticky rota is disabled.
    if init or not locked then
        self:onSetRotationMode(rotation_mode)
    end
end

function FileManager:init()
    if Device:isTouchDevice() then
        self:registerTouchZones({
            {
                id = "filemanager_swipe",
                ges = "swipe",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0,
                    ratio_w = Screen:getWidth(), ratio_h = Screen:getHeight(),
                },
                handler = function(ges)
                    self:onSwipeFM(ges)
                end,
            },
        })
    end
    self.show_parent = self.show_parent or self
    local icon_size = Screen:scaleBySize(35)
    local home_button = IconButton:new{
        icon_file = "resources/icons/appbar.home.png",
        scale_for_dpi = false,
        width = icon_size,
        height = icon_size,
        padding = Size.padding.default,
        padding_left = Size.padding.large,
        padding_right = Size.padding.large,
        padding_bottom = 0,
        callback = function() self:goHome() end,
        hold_callback = function() self:setHome() end,
    }

    local plus_button = IconButton:new{
        icon_file = "resources/icons/appbar.plus.png",
        scale_for_dpi = false,
        width = icon_size,
        height = icon_size,
        padding = Size.padding.default,
        padding_left = Size.padding.large,
        padding_right = Size.padding.large,
        padding_bottom = 0,
        callback = nil, -- top right corner callback handled by gesture manager
        hold_callback = nil, -- top right corner hold_callback handled by gesture manager
    }

    self.path_text = TextWidget:new{
        face = Font:getFace("xx_smallinfofont"),
        text = BD.directory(filemanagerutil.abbreviate(self.root_path)),
        max_width = Screen:getWidth() - 2*Size.padding.small,
        truncate_left = true,
    }

    self.banner = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        VerticalGroup:new {
            CenterContainer:new {
                dimen = { w = Screen:getWidth(), h = nil },
                HorizontalGroup:new {
                    home_button,
                    VerticalGroup:new {
                        Button:new {
                            readonly = true,
                            bordersize = 0,
                            padding = 0,
                            text_font_bold = false,
                            text_font_face = "smalltfont",
                            text_font_size = 24,
                            text = self.title,
                            width = Screen:getWidth() - 2 * icon_size - 4 * Size.padding.large,
                        },
                    },
                    plus_button,
                }
            },
            CenterContainer:new{
                dimen = { w = Screen:getWidth(), h = nil },
                self.path_text,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(5) },
        }
    }

    local g_show_hidden = G_reader_settings:readSetting("show_hidden")
    local show_hidden = g_show_hidden == nil and DSHOWHIDDENFILES or g_show_hidden
    local show_unsupported = G_reader_settings:readSetting("show_unsupported")
    local file_chooser = FileChooser:new{
        -- remember to adjust the height when new item is added to the group
        path = self.root_path,
        focused_path = self.focused_file,
        collate = G_reader_settings:readSetting("collate") or "strcoll",
        reverse_collate = G_reader_settings:isTrue("reverse_collate"),
        show_parent = self.show_parent,
        show_hidden = show_hidden,
        width = Screen:getWidth(),
        height = Screen:getHeight() - self.banner:getSize().h,
        is_popout = false,
        is_borderless = true,
        has_close_button = true,
        perpage = G_reader_settings:readSetting("items_per_page"),
        show_unsupported = show_unsupported,
        file_filter = function(filename)
            if DocumentRegistry:hasProvider(filename) then
                return true
            end
        end,
        close_callback = function() return self:onClose() end,
        -- allow left bottom tap gesture, otherwise it is eaten by hidden return button
        return_arrow_propagation = true,
        -- allow Menu widget to delegate handling of some gestures to GestureManager
        is_file_manager = true,
    }
    self.file_chooser = file_chooser
    self.focused_file = nil -- use it only once

    function file_chooser:onPathChanged(path)  -- luacheck: ignore
        FileManager.instance.path_text:setText(BD.directory(filemanagerutil.abbreviate(path)))
        UIManager:setDirty(FileManager.instance, function()
            return "ui", FileManager.instance.path_text.dimen, FileManager.instance.dithered
        end)
        return true
    end

    function file_chooser:onFileSelect(file)  -- luacheck: ignore
        FileManager.instance:onClose()
        ReaderUI:showReader(file)
        return true
    end

    local copyFile = function(file) self:copyFile(file) end
    local pasteHere = function(file) self:pasteHere(file) end
    local cutFile = function(file) self:cutFile(file) end
    local deleteFile = function(file) self:deleteFile(file) end
    local renameFile = function(file) self:renameFile(file) end
    local setHome = function(path) self:setHome(path) end
    local fileManager = self

    function file_chooser:onFileHold(file)  -- luacheck: ignore
        local buttons = {
            {
                {
                    text = C_("File", "Copy"),
                    callback = function()
                        copyFile(file)
                        UIManager:close(self.file_dialog)
                    end,
                },
                {
                    text = C_("File", "Paste"),
                    enabled = fileManager.clipboard and true or false,
                    callback = function()
                        pasteHere(file)
                        UIManager:close(self.file_dialog)
                    end,
                },
                {
                    text = _("Purge .sdr"),
                    enabled = DocSettings:hasSidecarFile(BaseUtil.realpath(file)),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Purge .sdr to reset settings for this document?\n\n%1"), BD.filename(self.file_dialog.title)),
                            ok_text = _("Purge"),
                            ok_callback = function()
                                filemanagerutil.purgeSettings(file)
                                require("readhistory"):fileSettingsPurged(file)
                                self:refreshPath()
                                UIManager:close(self.file_dialog)
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = _("Cut"),
                    callback = function()
                        cutFile(file)
                        UIManager:close(self.file_dialog)
                    end,
                },
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Are you sure that you want to delete this file?\n") .. BD.filepath(file) .. ("\n") .. _("If you delete a file, it is permanently lost."),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                deleteFile(file)
                                require("readhistory"):fileDeleted(file)
                                self:refreshPath()
                                UIManager:close(self.file_dialog)
                            end,
                        })
                    end,
                },
                {
                    text = _("Rename"),
                    callback = function()
                        UIManager:close(self.file_dialog)
                        fileManager.rename_dialog = InputDialog:new{
                            title = _("Rename file"),
                            input = BaseUtil.basename(file),
                            buttons = {{
                                {
                                    text = _("Cancel"),
                                    enabled = true,
                                    callback = function()
                                        UIManager:close(fileManager.rename_dialog)
                                    end,
                                },
                                {
                                    text = _("Rename"),
                                    enabled = true,
                                    callback = function()
                                        renameFile(file)
                                        self:refreshPath()
                                        UIManager:close(fileManager.rename_dialog)
                                    end,
                                },
                            }},
                        }
                        UIManager:show(fileManager.rename_dialog)
                        fileManager.rename_dialog:onShowKeyboard()
                    end,
                }
            },
            -- a little hack to get visual functionality grouping
            {
            },
        }

        if lfs.attributes(file, "mode") == "file" and Device:canExecuteScript(file) then
            -- NOTE: We populate the empty separator, in order not to mess with the button reordering code in CoverMenu
            table.insert(buttons[3],
                {
                    -- @translators This is the script's programming language (e.g., shell or python)
                    text = T(_("Execute %1 script"), util.getScriptType(file)),
                    enabled = true,
                    callback = function()
                        UIManager:close(self.file_dialog)
                        local script_is_running_msg = InfoMessage:new{
                                -- @translators %1 is the script's programming language (e.g., shell or python), %2 is the filename
                                text = T(_("Running %1 script %2…"), util.getScriptType(file), BD.filename(BaseUtil.basename(file))),
                        }
                        UIManager:show(script_is_running_msg)
                        UIManager:scheduleIn(0.5, function()
                            local rv
                            if Device:isAndroid() then
                                Device:setIgnoreInput(true)
                                rv = os.execute("sh " .. BaseUtil.realpath(file)) -- run by sh, because sdcard has no execute permissions
                                Device:setIgnoreInput(false)
                            else
                                rv = os.execute(BaseUtil.realpath(file))
                            end
                            UIManager:close(script_is_running_msg)
                            if rv == 0 then
                                UIManager:show(InfoMessage:new{
                                    text = _("The script exited successfully."),
                                })
                            else
                                --- @note: Lua 5.1 returns the raw return value from the os's system call. Counteract this madness.
                                UIManager:show(InfoMessage:new{
                                    text = T(_("The script returned a non-zero status code: %1!"), bit.rshift(rv, 8)),
                                    icon_file = "resources/info-warn.png",
                                })
                            end
                        end)
                    end,
                }
            )
        end

        if lfs.attributes(file, "mode") == "file" then
            table.insert(buttons, {
                {
                    text = _("Open with…"),
                    enabled = DocumentRegistry:getProviders(file) == nil or #(DocumentRegistry:getProviders(file)) > 1 or fileManager.texteditor,
                    callback = function()
                        UIManager:close(self.file_dialog)
                        local one_time_providers = {}
                        if fileManager.texteditor then
                            table.insert(one_time_providers, {
                                provider_name = _("Text editor"),
                                callback = function()
                                    fileManager.texteditor:checkEditFile(file)
                                end,
                            })
                        end
                        self:showSetProviderButtons(file, FileManager.instance, ReaderUI, one_time_providers)
                    end,
                },
                {
                    text = _("Book information"),
                    enabled = FileManagerBookInfo:isSupported(file),
                    callback = function()
                        FileManagerBookInfo:show(file)
                        UIManager:close(self.file_dialog)
                    end,
                }
            })
            table.insert(buttons, {
                {
                    text_func = function()
                        if ReadCollection:checkItemExist(file) then
                            return _("Remove from favorites")
                        else
                            return _("Add to favorites")
                        end
                    end,
                    enabled = DocumentRegistry:getProviders(file) ~= nil,
                    callback = function()
                        if ReadCollection:checkItemExist(file) then
                            ReadCollection:removeItem(file)
                        else
                            ReadCollection:addItem(file)
                        end
                        UIManager:close(self.file_dialog)
                    end,
                },
            })
            if FileManagerConverter:isSupported(file) then
                table.insert(buttons, {
                    {
                        text = _("Convert"),
                        enabled = true,
                        callback = function()
                            UIManager:close(self.file_dialog)
                            FileManagerConverter:showConvertButtons(file, self)
                        end,
                    }
                })
            end
        end
        if lfs.attributes(file, "mode") == "directory" then
            local realpath = BaseUtil.realpath(file)
            table.insert(buttons, {
                {
                    text = _("Set as HOME directory"),
                    callback = function()
                        setHome(realpath)
                        UIManager:close(self.file_dialog)
                    end
                }
            })
        end

        local title
        if lfs.attributes(file, "mode") == "directory" then
            title = BD.directory(file:match("([^/]+)$"))
        else
            title = BD.filename(file:match("([^/]+)$"))
        end

        self.file_dialog = ButtonDialogTitle:new{
            title = title,
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(self.file_dialog)
        return true
    end

    self.layout = VerticalGroup:new{
        self.banner,
        file_chooser,
    }

    local fm_ui = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.layout,
    }

    self[1] = fm_ui

    self.menu = FileManagerMenu:new{
        ui = self
    }
    self.active_widgets = { Screenshoter:new{ prefix = 'FileManager' } }
    table.insert(self, self.menu)
    table.insert(self, FileManagerHistory:new{
        ui = self,
    })
    table.insert(self, FileManagerCollection:new{
        ui = self,
    })
    table.insert(self, FileManagerFileSearcher:new{ ui = self })
    table.insert(self, FileManagerShortcuts:new{ ui = self })
    table.insert(self, ReaderDictionary:new{ ui = self })
    table.insert(self, ReaderWikipedia:new{ ui = self })
    table.insert(self, ReaderDeviceStatus:new{ ui = self })
    table.insert(self, DeviceListener:new{ ui = self })

    -- koreader plugins
    for _,plugin_module in ipairs(PluginLoader:loadPlugins()) do
        if not plugin_module.is_doc_only then
            local ok, plugin_or_err = PluginLoader:createPluginInstance(
                plugin_module, { ui = self, })
            -- Keep references to the modules which do not register into menu.
            if ok then
                local name = plugin_module.name
                if name then self[name] = plugin_or_err end
                table.insert(self, plugin_or_err)
                logger.info("FM loaded plugin", name,
                            "at", plugin_module.path)
            end
        end
    end

    if Device:hasWifiToggle() then
        local NetworkListener = require("ui/network/networklistener")
        table.insert(self, NetworkListener:new{ ui = self })
    end

    if Device:hasKeys() then
        self.key_events.Home = { {"Home"}, doc = "go home" }
        -- Override the menu.lua way of handling the back key
        self.file_chooser.key_events.Back = { {"Back"}, doc = "go back" }
        if not Device:hasFewKeys() then
            -- Also remove the handler assigned to the "Back" key by menu.lua
            self.file_chooser.key_events.Close = nil
        end
    end

    self:handleEvent(Event:new("SetDimensions", self.dimen))
end

function FileChooser:onBack()
    local back_to_exit = G_reader_settings:readSetting("back_to_exit") or "prompt"
    local back_in_filemanager = G_reader_settings:readSetting("back_in_filemanager") or "default"
    if back_in_filemanager == "default" then
        if back_to_exit == "always" then
            return self:onClose()
        elseif back_to_exit == "disable" then
            return true
        elseif back_to_exit == "prompt" then
                UIManager:show(ConfirmBox:new{
                    text = _("Exit KOReader?"),
                    ok_text = _("Exit"),
                    ok_callback = function()
                        self:onClose()
                    end
                })

            return true
        end
    elseif back_in_filemanager == "parent_folder" then
        self:changeToPath(string.format("%s/..", self.path))
        return true
    end
end

function FileManager:onShowPlusMenu()
    self:tapPlus()
    return true
end

function FileManager:onSwipeFM(ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
        self.file_chooser:onNextPage()
    elseif direction == "east" then
        self.file_chooser:onPrevPage()
    end
    return true
end

function FileManager:tapPlus()
    local buttons = {
        {
            {
                text = _("New folder"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self.input_dialog = InputDialog:new{
                        title = _("Create new folder"),
                        input_type = "text",
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    callback = function()
                                        self:closeInputDialog()
                                    end,
                                },
                                {
                                    text = _("Create"),
                                    callback = function()
                                        self:closeInputDialog()
                                        local new_folder = self.input_dialog:getInputText()
                                        if new_folder and new_folder ~= "" then
                                            self:createFolder(self.file_chooser.path, new_folder)
                                        end
                                    end,
                                },
                            }
                        },
                    }
                    UIManager:show(self.input_dialog)
                    self.input_dialog:onShowKeyboard()
                end,
            },
        },
        {
            {
                text = _("Paste"),
                enabled = self.clipboard and true or false,
                callback = function()
                    self:pasteHere(self.file_chooser.path)
                    self:onRefresh()
                    UIManager:close(self.file_dialog)
                end,
            },
        },
        {
            {
                text = _("Set as HOME directory"),
                callback = function()
                    self:setHome(self.file_chooser.path)
                    UIManager:close(self.file_dialog)
                end
            }
        },
        {
            {
                text = _("Go to HOME directory"),
                callback = function()
                    self:goHome()
                    UIManager:close(self.file_dialog)
                end
            }
        },
        {
            {
                text = _("Open random document"),
                callback = function()
                    self:openRandomFile(self.file_chooser.path)
                    UIManager:close(self.file_dialog)
                end
            }
        },
        {
            {
                text = _("Folder shortcuts"),
                callback = function()
                    self:handleEvent(Event:new("ShowFolderShortcutsDialog"))
                    UIManager:close(self.file_dialog)
                end
            }
        }
    }

    if Device:canImportFiles() then
        table.insert(buttons, 3, {
            {
                text = _("Import files here"),
                enabled = Device.isValidPath(self.file_chooser.path),
                callback = function()
                    local current_dir = self.file_chooser.path
                    UIManager:close(self.file_dialog)
                    Device.importFile(current_dir)
                end,
            },
        })
    end

    self.file_dialog = ButtonDialogTitle:new{
        title = BD.dirpath(filemanagerutil.abbreviate(self.file_chooser.path)),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.file_dialog)
end

function FileManager:reinit(path, focused_file)
    UIManager:flushSettings()
    self.dimen = Screen:getSize()
    -- backup the root path and path items
    self.root_path = path or self.file_chooser.path
    local path_items_backup = {}
    for k, v in pairs(self.file_chooser.path_items) do
        path_items_backup[k] = v
    end
    -- reinit filemanager
    self.focused_file = focused_file
    self:init()
    self.file_chooser.path_items = path_items_backup
    -- self:init() has already done file_chooser:refreshPath(), so this one
    -- looks like not necessary (cheap with classic mode, less cheap with
    -- CoverBrowser plugin's cover image renderings)
    -- self:onRefresh()
end

function FileManager:getCurrentDir()
    if self.instance then
        return self.instance.file_chooser.path
    end
end

function FileManager:toggleHiddenFiles()
    self.file_chooser:toggleHiddenFiles()
    G_reader_settings:saveSetting("show_hidden", self.file_chooser.show_hidden)
end

function FileManager:toggleUnsupportedFiles()
    self.file_chooser:toggleUnsupportedFiles()
    G_reader_settings:saveSetting("show_unsupported", self.file_chooser.show_unsupported)
end

function FileManager:setCollate(collate)
    self.file_chooser:setCollate(collate)
    G_reader_settings:saveSetting("collate", self.file_chooser.collate)
end

function FileManager:toggleReverseCollate()
    self.file_chooser:toggleReverseCollate()
    G_reader_settings:saveSetting("reverse_collate", self.file_chooser.reverse_collate)
end

function FileManager:onClose()
    logger.dbg("close filemanager")
    self:handleEvent(Event:new("SaveSettings"))
    G_reader_settings:flush()
    UIManager:close(self)
    if self.onExit then
        self:onExit()
    end
    return true
end

function FileManager:onRefresh()
    self.file_chooser:refreshPath()
    return true
end

function FileManager:goHome()
    local home_dir = G_reader_settings:readSetting("home_dir")
    if not home_dir or lfs.attributes(home_dir, "mode") ~= "directory"  then
        -- Try some sane defaults, depending on platform
        home_dir = Device.home_dir
    end
    if home_dir then
        -- Jump to the first page if we're already home
        if self.file_chooser.path and home_dir == self.file_chooser.path then
            self.file_chooser:onGotoPage(1)
        else
            self.file_chooser:changeToPath(home_dir)
        end
    else
        self:setHome()
    end
    return true
end

function FileManager:setHome(path)
    path = path or self.file_chooser.path
    UIManager:show(ConfirmBox:new{
        text = T(_("Set '%1' as HOME directory?"), BD.dirpath(path)),
        ok_text = _("Set as HOME"),
        ok_callback = function()
            G_reader_settings:saveSetting("home_dir", path)
        end,
    })
    return true
end

function FileManager:openRandomFile(dir)
    local random_file = DocumentRegistry:getRandomFile(dir, false)
    if random_file then
        UIManager:show(MultiConfirmBox:new {
            text = T(_("Do you want to open %1?"), BD.filename(BaseUtil.basename(random_file))),
            choice1_text = _("Open"),
            choice1_callback = function()
                FileManager.instance:onClose()
                ReaderUI:showReader(random_file)

            end,
            -- @translators Another file. This is a button on the open random file dialog. It presents a file with the choices Open/Another.
            choice2_text = _("Another"),
            choice2_callback = function()
                self:openRandomFile(dir)
            end,
        })
        UIManager:close(self.file_dialog)
    else
        UIManager:show(InfoMessage:new {
            text = _("File not found"),
        })
    end
end

function FileManager:copyFile(file)
    self.cutfile = false
    self.clipboard = file
end

function FileManager:cutFile(file)
    self.cutfile = true
    self.clipboard = file
end

function FileManager:pasteHere(file)
    if self.clipboard then
        file = BaseUtil.realpath(file)
        local orig = BaseUtil.realpath(self.clipboard)
        local dest = lfs.attributes(file, "mode") == "directory" and
            file or file:match("(.*/)")

        local function infoCopyFile()
            -- if we copy a file, also copy its sidecar directory
            if DocSettings:hasSidecarFile(orig) then
                BaseUtil.execute(self.cp_bin, "-r", DocSettings:getSidecarDir(orig), dest)
            end
            if BaseUtil.execute(self.cp_bin, "-r", orig, dest) == 0 then
                UIManager:show(InfoMessage:new {
                    text = T(_("Copied to: %1"), BD.dirpath(dest)),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new {
                    text = T(_("An error occurred while trying to copy %1"), BD.filepath(orig)),
                    timeout = 2,
                })
            end
        end

        local function infoMoveFile()
            -- if we move a file, also move its sidecar directory
            if DocSettings:hasSidecarFile(orig) then
                self:moveFile(DocSettings:getSidecarDir(orig), dest) -- dest is always a directory
            end
            if self:moveFile(orig, dest) then
                -- Update history and collections.
                local dest_file = string.format("%s/%s", dest, BaseUtil.basename(orig))
                require("readhistory"):updateItemByPath(orig, dest_file) -- (will update "lastfile" if needed)
                ReadCollection:updateItemByPath(orig, dest_file)
                UIManager:show(InfoMessage:new {
                    text = T(_("Moved to: %1"), BD.dirpath(dest)),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new {
                    text = T(_("An error occurred while trying to move %1"), BD.filepath(orig)),
                    timeout = 2,
                })
            end
        end

        local info_file
        if self.cutfile then
            info_file = infoMoveFile
        else
            info_file = infoCopyFile
        end
        local basename = BaseUtil.basename(self.clipboard)
        local mode = lfs.attributes(string.format("%s/%s", dest, basename), "mode")
        if mode == "file" or mode == "directory" then
            local text
            if mode == "file" then
                text = T(_("The file %1 already exists. Do you want to overwrite it?"), BD.filename(basename))
            else
                text = T(_("The directory %1 already exists. Do you want to overwrite it?"), BD.directory(basename))
            end

            UIManager:show(ConfirmBox:new {
                text = text,
                ok_text = _("Overwrite"),
                ok_callback = function()
                    info_file()
                    self:onRefresh()
                    self.clipboard = nil
                end,
            })
        else
            info_file()
            self:onRefresh()
            self.clipboard = nil
        end
    end
end

function FileManager:createFolder(curr_folder, new_folder)
    local folder = string.format("%s/%s", curr_folder, new_folder)
    local code = BaseUtil.execute(self.mkdir_bin, folder)
    local text
    if code == 0 then
        self:onRefresh()
        text = T(_("Folder created:\n%1"), BD.directory(new_folder))
    else
        text = _("The folder has not been created.")
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 2,
    })
end

function FileManager:deleteFile(file)
    local ok, err, is_dir
    local file_abs_path = BaseUtil.realpath(file)
    if file_abs_path == nil then
        UIManager:show(InfoMessage:new{
            text = T(_("File %1 not found"), BD.filepath(file)),
        })
        return
    end

    local is_doc = DocumentRegistry:hasProvider(file_abs_path)
    if lfs.attributes(file_abs_path, "mode") == "file" then
        ok, err = os.remove(file_abs_path)
    else
        ok, err = BaseUtil.purgeDir(file_abs_path)
        is_dir = true
    end
    if ok and not err then
        if is_doc then
            local doc_settings = DocSettings:open(file)
            -- remove cache if any
            local cache_file_path = doc_settings:readSetting("cache_file_path")
            if cache_file_path then
                os.remove(cache_file_path)
            end
            doc_settings:purge()
        end
        ReadCollection:removeItemByPath(file, is_dir)
        UIManager:show(InfoMessage:new{
            text = T(_("Deleted %1"), BD.filepath(file)),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("An error occurred while trying to delete %1"), BD.filepath(file)),
        })
    end
end

function FileManager:renameFile(file)
    if BaseUtil.basename(file) ~= self.rename_dialog:getInputText() then
        local dest = BaseUtil.joinPath(BaseUtil.dirname(file), self.rename_dialog:getInputText())
        if self:moveFile(file, dest) then
            require("readhistory"):updateItemByPath(file, dest) -- (will update "lastfile" if needed)
            ReadCollection:updateItemByPath(file, dest)
            if lfs.attributes(dest, "mode") == "file" then
                local doc = require("docsettings")
                local move_history = true;
                if lfs.attributes(doc:getHistoryPath(file), "mode") == "file" and
                   not self:moveFile(doc:getHistoryPath(file), doc:getHistoryPath(dest)) then
                   move_history = false
                end
                if lfs.attributes(doc:getSidecarDir(file), "mode") == "directory" and
                   not self:moveFile(doc:getSidecarDir(file), doc:getSidecarDir(dest)) then
                   move_history = false
                end
                if move_history then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Renamed from %1 to %2"), BD.filepath(file), BD.filepath(dest)),
                        timeout = 2,
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = T(
                            _("Failed to move history data of %1 to %2.\nThe reading history may be lost."),
                            BD.filepath(file), BD.filepath(dest)),
                    })
                end
            end
        else
            UIManager:show(InfoMessage:new{
                text = T(
                    _("Failed to rename from %1 to %2"), BD.filepath(file), BD.filepath(dest)),
            })
        end
    end
end

function FileManager:getSortingMenuTable()
    local fm = self
    local collates = {
        strcoll = {_("filename"), _("Sort by filename")},
        numeric = {_("numeric"), _("Sort by filename (natural sorting)")},
        strcoll_mixed = {_("name mixed"), _("Sort by name – mixed files and folders")},
        access = {_("date read"), _("Sort by last read date")},
        change = {_("date added"), _("Sort by date added")},
        modification = {_("date modified"), _("Sort by date modified")},
        size = {_("size"), _("Sort by size")},
        type = {_("type"), _("Sort by type")},
        percent_unopened_first = {_("percent – unopened first"), _("Sort by percent – unopened first")},
        percent_unopened_last = {_("percent – unopened last"), _("Sort by percent – unopened last")},
    }
    local set_collate_table = function(collate)
        return {
            text = collates[collate][2],
            checked_func = function()
                return fm.file_chooser.collate == collate
            end,
            callback = function() fm:setCollate(collate) end,
        }
    end
    local get_collate_percent = function()
        local collate_type = G_reader_settings:readSetting("collate")
        if collate_type == "percent_unopened_first" or collate_type == "percent_unopened_last" then
            return collates[collate_type][2]
        else
            return _("Sort by percent")
        end
    end
    return {
        text_func = function()
            return T(
                _("Sort by: %1"),
                collates[fm.file_chooser.collate][1]
            )
        end,
        sub_item_table = {
            set_collate_table("strcoll"),
            set_collate_table("numeric"),
            set_collate_table("strcoll_mixed"),
            set_collate_table("access"),
            set_collate_table("change"),
            set_collate_table("modification"),
            set_collate_table("size"),
            set_collate_table("type"),
            {
                text_func =  get_collate_percent,
                checked_func = function()
                    return fm.file_chooser.collate == "percent_unopened_first"
                        or fm.file_chooser.collate == "percent_unopened_last"
                end,
                sub_item_table = {
                    set_collate_table("percent_unopened_first"),
                    set_collate_table("percent_unopened_last"),
                }
            },
        }
    }
end

function FileManager:getStartWithMenuTable()
    local start_with_setting = G_reader_settings:readSetting("start_with") or "filemanager"
    local start_withs = {
        filemanager = {_("file browser"), _("Start with file browser")},
        history = {_("history"), _("Start with history")},
        favorites = {_("favorites"), _("Start with favorites")},
        folder_shortcuts = {_("folder shortcuts"), _("Start with folder shortcuts")},
        last = {_("last file"), _("Start with last file")},
    }
    local set_sw_table = function(start_with)
        return {
            text = start_withs[start_with][2],
            checked_func = function()
                return start_with_setting == start_with
            end,
            callback = function()
                start_with_setting = start_with
                G_reader_settings:saveSetting("start_with", start_with)
            end,
        }
    end
    return {
        text_func = function()
            return T(
                _("Start with: %1"),
                start_withs[start_with_setting][1]
            )
        end,
        sub_item_table = {
            set_sw_table("filemanager"),
            set_sw_table("history"),
            set_sw_table("favorites"),
            set_sw_table("folder_shortcuts"),
            set_sw_table("last"),
        }
    }
end

function FileManager:showFiles(path, focused_file)
    path = path or G_reader_settings:readSetting("lastdir") or filemanagerutil.getDefaultDir()
    G_reader_settings:saveSetting("lastdir", path)
    self:setRotationMode()
    local file_manager = FileManager:new{
        dimen = Screen:getSize(),
        covers_fullscreen = true, -- hint for UIManager:_repaint()
        root_path = path,
        focused_file = focused_file,
        onExit = function()
            self.instance = nil
        end
    }
    UIManager:show(file_manager)
    self.instance = file_manager
end

--- A shortcut to execute mv.
-- @treturn boolean result of mv command
function FileManager:moveFile(from, to)
    return BaseUtil.execute(self.mv_bin, from, to) == 0
end

--- A shortcut to execute cp.
-- @treturn boolean result of cp command
function FileManager:copyFileFromTo(from, to)
    return BaseUtil.execute(self.cp_bin, from, to) == 0
end

--- A shortcut to execute cp recursively.
-- @treturn boolean result of cp command
function FileManager:copyRecursive(from, to)
    return BaseUtil.execute(self.cp_bin, "-r", from, to ) == 0
end

function FileManager:onHome()
    return self:goHome()
end

return FileManager
