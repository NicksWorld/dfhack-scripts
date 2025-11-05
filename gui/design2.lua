local gui = require('gui')
local guidm = require('gui.dwarfmode')
local overlay = require('plugins.overlay')
local plugin = require('plugins.design')
local quickfort = reqscript('quickfort')
local shapes = reqscript('internal/design/shapes')
local textures = require('gui.textures')
local util = reqscript('internal/design/util')
local utils = require('utils')
local widgets = require('gui.widgets')

-- UI Layout
-- Mode modal (draw/copy/paste)
-- Draw
-- - Erase option available in all modes
-- - Split function into modes: dig, smooth/engrave, construct, "other" (woodcutting, gathering, stockpiles, etc.)
-- - dig needs mine, stair, ramp, channel. Needs priority, overwrite other designations, and destroy constructions options.
-- - Smooth/engrave needs smooth, engrave, gap carve, track engrave (allowing composite lines using curve tool, 3d required)
-- - Construct needs walls, floors, fortifications, paved/dirt roads, farm plots (single-layer, may need restrictions), glass/gem windows, grates?, bars?
-- Copy
-- - Build a selection, possibly using a composite made through drawing selection bounds (hold shift for additive, ctrl for negative?)
-- - Allow "phase options" from blueprint
-- - Allow "clipboard" for immediate use in Paste mode, or saving as a blueprint file
-- Paste
-- - Allow pasting last copied in-memory blueprint
-- - Allow opening a blueprint, using portions of gui/quickfort
-- - Quick rotate, flip, (scale?) options
-- - Repeat option for automatic tiling? (x/y count pos and neg, x/y stride
-- - Draggable center point

-- Other Features
-- - Keyboard cursor support, detect and use as alternative to mouse pos and clicking?

local function make_button_spec(ch1, ch2, ch1_color, ch2_color, x, y, x_selected, y_selected)
    y_selected = y_selected or y
    return {
        button_spec=util.make_button_spec(ch1, ch2, ch1_color, ch2_color, COLOR_GRAY, COLOR_WHITE, x, y),
        button_selected_spec=util.make_button_spec(ch1, ch2, ch1_color, ch2_color, COLOR_YELLOW, COLOR_YELLOW, x_selected, y_selected),
    }
end

-- Selection Representation
Selection = defclass(Selection)
Selection.ATTRS {
    voxels = {}
}

function Selection:set(x, y, z, val)
    if val then
        self.voxels[z] = self.voxels[z] or {}
        self.voxels[z][x] = self.voxels[z][x] or {}
        self.voxels[z][x][y] = true
    elseif self.voxels[z] and self.voxels[z][x] then
        self.voxels[z][x][y] = nil
    end
end

-- Drawing Tool Interface
IDrawingTool = defclass(IDrawingTool, widgets.ResizingPanel)
IDrawingTool.ATTRS = {
    -- Determines button visibility in non-3d designations
    -- use for shapes that are 3d-exclusive, ex. cone/spiral
    three_dimensional = false,

    name = DEFAULT_NIL,
    button_spec = DEFAULT_NIL,
    button_selected_spec = DEFAULT_NIL,

    -- Current selection state, persists between tools
    selection = DEFAULT_NIL,
}

-- Brush Tool
BrushTool = defclass(BrushTool, IDrawingTool)
BrushTool.ATTRS = {
    three_dimensional = false,

    name = 'Brush',

    erasing = false,
    last_mouse_pos = DEFAULT_NIL,
}


-- TODO move to utils
local function getMousePrecise()
    local pos = {x=df.global.window_x,y=df.global.window_y,z=df.global.window_z}
    if dfhack.screen.inGraphicsMode() then
        local tile_pixels = df.global.gps.viewport_zoom_factor / 4
        pos.x = pos.x + df.global.gps.precise_mouse_x / tile_pixels
        pos.y = pos.y + df.global.gps.precise_mouse_y / tile_pixels
    else
        pos.x = pos.x + df.global.gps.mouse_x
        pos.y = pos.y + df.global.gps.mouse_y
    end
    return pos
end

function BrushTool:init()
    local spec = make_button_spec('~', '\\', COLOR_MAGENTA, COLOR_LIGHTGRAY, 8, 19, 8, 28)
    self.button_spec = spec.button_spec
    self.button_selected_spec = spec.button_selected_spec

    self:addviews({
        widgets.ToggleHotkeyLabel{
            key = 'CUSTOM_E',
            label='Erase: ',
            initial_option=self.erasing,
            on_change = function(val) self.erasing=val end,
        },
    })
end

function BrushTool:drawAtPoint(point)
    self.selection:set(point.x, point.y, point.z, not self.erasing)
end

function BrushTool:onInput(keys)
    if BrushTool.super.onInput(self, keys) then
        return true
    end

    if keys._MOUSE_L then
        -- Initial click
        self.last_mouse_pos = getMousePrecise()
        self:drawAtPoint(self.last_mouse_pos)
    end

    if keys._MOUSE_L_DOWN then
        local mouse_pos = getMousePrecise()
        if mouse_pos.z ~= self.last_mouse_pos.z then
            -- Don't attempt interpolating between layers
            self.last_mouse_pos = mouse_pos
        end

        if mouse_pos == self.last_mouse_pos then
            return true
        end

        local bounds_precise = {
            x1 = math.min(mouse_pos.x, self.last_mouse_pos.x),
            x2 = math.max(mouse_pos.x, self.last_mouse_pos.x),
            y1 = math.min(mouse_pos.y, self.last_mouse_pos.y),
            y2 = math.max(mouse_pos.y, self.last_mouse_pos.y),
        }

        local bounds = {
            x1 = math.floor(bounds_precise.x1),
            x2 = math.floor(bounds_precise.x2),
            y1 = math.floor(bounds_precise.y1),
            y2 = math.floor(bounds_precise.y2)
        }
        if bounds.x1 == bounds.x2 then
            for y = bounds.y1,bounds.y2,1 do
                self:drawAtPoint({x=bounds.x1, y=y, z=mouse_pos.z})
                self.last_mouse_pos = mouse_pos
            end
            return true
        end
        if bounds.y1 == bounds.y2 then
            for x = bounds.x1,bounds.x2,1 do
                self:drawAtPoint({x=x,y=bounds.y1,z=mouse_pos.z})
                self.last_mouse_pos = mouse_pos
            end
            return true
        end

        local slope = (mouse_pos.y - self.last_mouse_pos.y) / (mouse_pos.x - self.last_mouse_pos.x)
        for x = bounds.x1,bounds.x2,1 do
            local a = bounds_precise.y1 + ((x - 0.4 - bounds_precise.x1) * slope)
            local b = bounds_precise.y1 + ((x + 0.4 - bounds_precise.x1) * slope)
            local min = math.floor(math.min(a,b) + 0.5)
            local max = math.floor(math.max(a,b) + 0.5)

            for y = math.max(min, bounds.y1),math.min(max, bounds.y2),1 do
                self:drawAtPoint({x=x, y=y, z=mouse_pos.z})
            end
        end

        self.last_mouse_pos = mouse_pos
        return true
    end
    return false
end

function BrushTool:select()
    return self.selection
end

function BrushTool:render_tool(existing_selection)
    local z = df.global.window_z
    plugin.design_load_shape(0, self.selection.voxels[z] or {})
    plugin.design_draw_shape(0)
end

-- Drawing/Selection UI
DrawingPanel = defclass(DrawingPanel, widgets.Panel)
DrawingPanel.ATTRS = {
    view_id = 'draw_panel',
    autoarrange_subviews=1,

    -- Allow multi-level selections (disabled for farmplots, etc.)
    -- Additionally enables/disables the additional 3d shapes
    three_dimensional = true,
    -- Show fullscreen grid over world in graphics mode, or cross from mouse in classic
    show_alignment_grid = true,
    -- Whether to automatically apply a selection on shape completion
    auto_commit = false,

    selection = Selection{}
}

function DrawingPanel:init()
    self.tools = {
        BrushTool{selection=self.selection},
    }
    self.active_tool=self.tools[1]
    self.show_guides = true

    -- Assemble tool button group
    local tool_options, tool_button_specs, tool_button_specs_selected = {}, {}, {}
    for _, tool in ipairs(self.tools) do
        table.insert(tool_options, {label = tool.name, value = tool})
        table.insert(tool_button_specs, tool.button_spec)
        table.insert(tool_button_specs_selected, tool.button_selected_spec)
    end

    -- Assemble tool option panel
    local tool_option_panel = widgets.ResizingPanel{
        autoarrange_subviews=true,
    }
    for _, tool in ipairs(self.tools) do
        tool_option_panel:addviews({tool})
    end

    self:addviews({
        widgets.ButtonGroup{
            view_id='tool',
            key='CUSTOM_Z',
            key_back='CUSTOM_SHIFT_Z',
            label='Tool:',
            options=tool_options,
            on_change=function(new_tool) self:change_tool(new_tool) end,
            button_specs=tool_button_specs,
            button_specs_selected=tool_button_specs_selected,
        },
        widgets.Divider{
            frame = {h = 1},
            frame_style = gui.FRAME_THIN,
            frame_style_l = false,
            frame_style_r = false,
        },
        tool_option_panel,
    })
end

function DrawingPanel:change_tool(new_tool)
    -- Changing to current tool, ignore
    if self.active_tool == new_tool then return end
end

local guide_tile_pen = dfhack.pen.parse {
    ch = '+',
    fg = COLOR_YELLOW,
    tile = dfhack.screen.findGraphicsTile('CURSORS', 0, 22),
}

function DrawingPanel:onRenderFrame(dc, rect)
    if self.show_guides then
        local mouse_pos = dfhack.gui.getMousePos()
        if dfhack.screen.inGraphicsMode() then
            local rc = gui.ViewRect{}
            dfhack.screen.fillRect(guide_tile_pen, rc.x1, rc.y1, rc.x2, rc.y2, true)
        elseif mouse_pos then
            -- TODO: Optimize using fillRect
            -- FIXME: Renders over ui elements
            local map_x, map_y = dfhack.maps.getTileSize()
            local horiz_bounds = {x1 = 0, x2 = map_x, y1=mouse_pos.y, y2=mouse_pos.y, z1=mouse_pos.z, z2=mouse_pos.z}
            guidm.renderMapOverlay(function() return guide_tile_pen end, horiz_bounds)
            local vert_bounds = {x1 = mouse_pos.x, x2 = mouse_pos.x, y1=0, y2=map_y, z1=mouse_pos.z, z2=mouse_pos.z}
            guidm.renderMapOverlay(function() return guide_tile_pen end, vert_bounds)
        end
    end

    self.tools[1]:render_tool(self.current_selection)
end

local DesignTab = {
    Draw = 1,
    Copy = 2,
    Paste = 3,
}
local DrawCategoryMode = {
    Dig = 1,
    SmoothEngrave = 2,
    Construct = 3,
    Misc = 4,
    Erase = 5,
}

local function make_mode_option(mode, ch1, ch2, ch1_color, ch2_color, x, y, x_selected, y_selected)
    y_selected = y_selected or y
    return {
        mode=mode,
        button_spec=util.make_button_spec(ch1, ch2, ch1_color, ch2_color, COLOR_GRAY, COLOR_WHITE, x, y),
        button_selected_spec=util.make_button_spec(ch1, ch2, ch1_color, ch2_color, COLOR_YELLOW, COLOR_YELLOW, x_selected, y_selected),
    }
end


local function primary_button_group(on_change)
    local mode_options = {
        {label='Dig', value=make_mode_option(DrawCategoryMode.Dig, '-', ')', COLOR_BROWN, COLOR_GRAY, 0, 22, 4)},
        {label='Smooth and Engrave', value=make_mode_option(DrawCategoryMode.SmoothEngrave, 177, 219, COLOR_GRAY, COLOR_WHITE, 0, 55, 4)},
        {label='Construct', value=make_mode_option(DrawCategoryMode.Construct, 210, 229, COLOR_BROWN, COLOR_DARKGRAY, 16, 31, 20)},
        -- TODO: Decide on better icon than plant gathering, and fix color in ascii mode
        {label='Misc', value=make_mode_option(DrawCategoryMode.Misc, '"', '"', COLOR_YELLOW, COLOR_YELLOW, 8, 52, 12)},
        {label='Erase', value=make_mode_option(DrawCategoryMode.Erase, 'X', 'X', COLOR_LIGHTRED, COLOR_LIGHTRED, 24, 28, 12)},
    }

    local specs, specs_selected = {}, {}
    for _, mode in ipairs(mode_options) do
        table.insert(specs, mode.value.button_spec)
        table.insert(specs_selected, mode.value.button_selected_spec)
    end

    return widgets.ButtonGroup {
        view_id = 'mode',
        key = 'CUSTOM_F',
        key_back = 'CUSTOM_SHIFT_F',
        label = 'Mode:',
        on_change = on_change,

        options = mode_options,
        button_specs = specs,
        button_specs_selected = specs_selected,
    }
end

-- Design Window
Design = defclass(Design, widgets.Window)
Design.ATTRS {
    frame_title = 'Design',
    frame={w=40, h=48, r=2, t=18},
    resizable = true,

    tab = DesignTab.Draw,
    autoarrange_subviews=true,
    autoarrange_gap=1,
}

function Design:init()
    local on_change = function() self.needs_update=true end
    self:addviews{
        -- widgets.TabBar {
        --     labels = {'Draw', 'Copy', 'Paste'},
        --     get_cur_page = function() return self.tab end,
        --     on_select = function(tab) self.tab = tab end,
        -- },
        -- primary_button_group(on_change),
        DrawingPanel {},
    }
end

-- Design Screen
DesignScreen = defclass(DesignScreen, gui.ZScreen)
DesignScreen.ATTRS {
    focus_path='design',
    pass_movement_keys=true,
    pass_mouse_clicks=false,
}

function DesignScreen:init()
    self.design_window = Design{}
    self:addviews{
        self.design_window,
        -- TODO: DimensionsTooltip
    }
end

function DesignScreen:onDismiss()
    view = nil
end

if dfhack_flags.module then return end

if not dfhack.isMapLoaded() then
    qerror('This script requires a fortress map to be loaded')
end

view = view and view:raise() or DesignScreen{}:show()
