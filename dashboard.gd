extends Control

const LanMotion = preload("res://lan_motion.gd")
const QrCode = preload("res://qr_code.gd")
const PhonePose = preload("res://phone_pose.gd")

const BACKGROUND := Color("#101518")
const SURFACE := Color("#191f23")
const WELL := Color("#13191c")
const LINE := Color("#303a3e")
const MUTED := Color("#a8b4b8")
const INK := Color("#f1f5ef")
const ACCENTS := [Color("#a6f0c9"), Color("#ffd492")]
const CARD_X := [64, 612]
const GROUPS := ["加速度 · 去重力", "加速度 · 含重力", "陀螺仪 · 旋转速率"]
const AXES := ["X", "Y", "Z", "X", "Y", "Z", "α", "β", "γ"]
const BUTTONS := ["A", "B", "X", "Y"]
const STATES := {
	"disconnected": "等待扫码",
	"waiting": "传感器未开启",
	"denied": "权限未授予",
	"unsupported": "浏览器不支持",
	"no_data": "等待传感器数据",
	"paused": "传感器已暂停",
	"live": "传感器接收中"
}

var _server := LanMotion.new()
var _font := SystemFont.new()
var _heavy := SystemFont.new()
var _mono := ThemeDB.fallback_font
var _addresses: Array[String] = []
var _selected_address := 0
var _qr: Array[ImageTexture] = []
var _copy: Array[Button] = []
var _poses: Array[PhonePose] = []

func _ready() -> void:
	for font in [_font, _heavy]:
		font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC"])
	_heavy.font_weight = 700
	_addresses = _local_addresses()
	_server.addresses = _addresses
	_server.player_changed.connect(_update_player)
	add_child(_server)
	for player in range(2):
		var button := _button("复制连接", Rect2(CARD_X[player] + 186, 348, 108, 35))
		button.pressed.connect(_copy_link.bind(player))
		button.visible = _server.setup_port != 0
		_copy.append(button)
		_add_pose_preview(player)
	var address_button := _button("切换地址", Rect2(1024, 738, 112, 34))
	address_button.visible = _addresses.size() > 1 and _server.setup_port != 0
	address_button.pressed.connect(_switch_address)
	_refresh_codes()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND)
	_text("双人手机体感手柄", Vector2(64, 85), 44, INK, _heavy)
	var instructions := "手机与电脑连同一 Wi-Fi。首次扫码请安装本地证书，再开启传感器。"
	if not _server.error.is_empty():
		instructions = _server.error
	elif _addresses[_selected_address] == "127.0.0.1":
		instructions = "未检测到局域网地址。电脑连上 Wi-Fi 后请重启项目。"
	_text(instructions, Vector2(66, 124), 18, MUTED)
	var count := int(_server.is_connected_player(0)) + int(_server.is_connected_player(1))
	_pill(Rect2(981, 57, 155, 42), "%d / 2 已连接" % count, INK, count > 0)
	for player in range(2):
		_draw_player(player)
	if _server.setup_port > 0:
		_text("连接地址  %s:%d" % [_addresses[_selected_address], _server.setup_port],
			Vector2(64, 760), 16, MUTED)

func _draw_player(player: int) -> void:
	var x: int = CARD_X[player]
	var accent: Color = ACCENTS[player]
	_panel(Rect2(x, 161, 524, 558), SURFACE, 22, LINE)
	_text("玩家 %d" % (player + 1), Vector2(x + 27, 215), 34, accent, _heavy)
	var state := _server.player_state(player)
	var label: String = STATES[state] if _server.setup_port > 0 else "服务不可用"
	_pill(Rect2(x + 345, 187, 152, 36), label, accent, state == "live")
	draw_line(Vector2(x + 27, 239), Vector2(x + 497, 239), LINE)
	var qr_rect := Rect2(x + 27, 251, 148, 148)
	if _qr.size() == 2:
		draw_texture_rect(_qr[player], qr_rect, false)
	else:
		_panel(qr_rect, WELL, 9, LINE)
		_text("无二维码", Vector2(x + 65, 332), 16, MUTED)
	_text("扫码连接", Vector2(x + 186, 286), 22, INK, _heavy)
	_text("在手机上开启", Vector2(x + 186, 312), 14, MUTED)
	_text("传感器查看姿态", Vector2(x + 186, 332), 14, MUTED)
	_panel(Rect2(x + 310, 251, 187, 148), WELL, 12, LINE)
	_text("手机姿态", Vector2(x + 322, 272), 14, INK, _heavy)
	var has_pose := _server.player_pose(player) != null
	_text("实时跟随" if has_pose else "等待姿态数据", Vector2(x + 322, 389), 12,
		accent if has_pose else MUTED)
	draw_line(Vector2(x + 27, 413), Vector2(x + 497, 413), LINE)
	_draw_input(player, x, accent)
	draw_line(Vector2(x + 27, 518), Vector2(x + 497, 518), LINE)
	var sample := _server.player_sample(player)
	for group in range(GROUPS.size()):
		var top := 523 + group * 62
		_text(GROUPS[group], Vector2(x + 27, top + 17), 15, INK, _heavy)
		_text("m/s²" if group < 2 else "°/s", Vector2(x + 451, top + 17), 13, MUTED)
		for axis in range(3):
			var index := group * 3 + axis
			_draw_reading(Rect2(x + 27 + axis * 159, top + 24, 151, 33),
				AXES[index], sample[index], accent)

func _draw_input(player: int, x: int, accent: Color) -> void:
	var stick := _server.player_stick(player)
	var buttons := _server.player_buttons(player)
	var connected := _server.is_connected_player(player)
	_text("摇杆", Vector2(x + 27, 440), 16, INK, _heavy)
	_text("按键", Vector2(x + 282, 440), 16, INK, _heavy)
	var center := Vector2(x + 59, 478)
	draw_circle(center, 28, WELL, true, -1.0, true)
	draw_arc(center, 28, 0.0, TAU, 48, LINE, 1.0, true)
	draw_line(center - Vector2(16, 0), center + Vector2(16, 0), LINE)
	draw_line(center - Vector2(0, 16), center + Vector2(0, 16), LINE)
	var offset := Vector2(stick.x, -stick.y) * 19.0
	draw_circle(center + offset, 7, accent if connected else MUTED, true, -1.0, true)
	var text_color := accent if connected else MUTED
	_text("X  " + ("%+.2f" % stick.x if connected else "—"),
		Vector2(x + 106, 474), 16, text_color, _mono)
	_text("Y  " + ("%+.2f" % stick.y if connected else "—"),
		Vector2(x + 106, 496), 16, text_color, _mono)
	for index in range(BUTTONS.size()):
		var left := x + 282 + index * 55
		var held := bool(buttons & (1 << index))
		_panel(Rect2(left, 454, 49, 48), accent if held else WELL, 9, accent if held else LINE)
		_text(BUTTONS[index], Vector2(left + 17, 485), 19, BACKGROUND if held else MUTED, _heavy)

func _add_pose_preview(player: int) -> void:
	var preview := PhonePose.new()
	preview.accent = ACCENTS[player]
	add_child(preview)
	_poses.append(preview)
	var display := TextureRect.new()
	display.texture = preview.get_texture()
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.position = Vector2(CARD_X[player] + 318, 273)
	display.size = Vector2(171, 116)
	add_child(display)

func _update_player(player: int) -> void:
	_poses[player].set_angles(_server.player_pose(player))
	queue_redraw()

func _draw_reading(rect: Rect2, axis: String, value: Variant, accent: Color) -> void:
	_panel(rect, WELL, 9, LINE)
	_text(axis, rect.position + Vector2(12, 22), 13, MUTED, _heavy)
	var reading := "—"
	if value != null:
		var amount := float(value)
		if absf(amount) >= 100000.0:
			reading = "超量程"
		else:
			if absf(amount) < 0.005:
				amount = 0.0
			reading = "%+.2f" % amount
	var font: Font = _font if reading == "超量程" else _mono
	var width := font.get_string_size(reading, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	_text(reading, rect.position + Vector2(rect.size.x - 12 - width, 23), 18,
		MUTED if value == null else accent, font)

func _text(value: String, baseline: Vector2, font_size: int, color: Color,
		font: Font = null) -> void:
	draw_string(_font if font == null else font, baseline, value,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _panel(rect: Rect2, fill: Color, radius: int, border: Color) -> void:
	draw_style_box(_style(fill, radius, border), rect)

func _style(fill: Color, radius: int, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(radius)
	style.border_color = border
	style.set_border_width_all(1)
	return style

func _pill(rect: Rect2, label: String, color: Color, active: bool) -> void:
	_panel(rect, Color("#253431") if active else WELL, 19, LINE)
	draw_circle(rect.position + Vector2(17, rect.size.y / 2), 3.5,
		color if active else Color("#78868a"), true, -1.0, true)
	_text(label, rect.position + Vector2(30, (rect.size.y + 10) / 2.0),
		15, color if active else MUTED)

func _button(label: String, rect: Rect2) -> Button:
	var button := Button.new()
	button.text = label
	button.position = rect.position
	button.size = rect.size
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", _font)
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_stylebox_override("normal", _style(SURFACE, 8, LINE))
	button.add_theme_stylebox_override("hover", _style(Color("#2a363b"), 8, MUTED))
	button.add_theme_stylebox_override("pressed", _style(WELL, 8, MUTED))
	button.add_theme_stylebox_override("focus", _style(Color.TRANSPARENT, 8, INK))
	add_child(button)
	return button

func _local_addresses() -> Array[String]:
	var preferred: Array[String] = []
	var other: Array[String] = []
	for interface in IP.get_local_interfaces():
		var name: String = interface.get("name", "")
		for address: String in interface.get("addresses", []):
			if address.contains(":") or address.begins_with("127.") or address.begins_with("169.254.") \
					or address == "0.0.0.0" or address in preferred or address in other:
				continue
			if name == "en0":
				preferred.push_front(address)
			elif name.begins_with("en") or name.begins_with("eth") or name.begins_with("wl"):
				preferred.append(address)
			else:
				other.append(address)
	preferred.append_array(other)
	if preferred.is_empty():
		preferred.append("127.0.0.1")
	return preferred

func _refresh_codes() -> void:
	if _server.setup_port == 0:
		return
	_qr.clear()
	var encoder := QrCode.new()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for player in range(2):
		_qr.append(encoder.make_texture(_server.player_url(_addresses[_selected_address], player)))
		_copy[player].text = "复制连接"
	queue_redraw()

func _switch_address() -> void:
	_selected_address = (_selected_address + 1) % _addresses.size()
	_refresh_codes()

func _copy_link(player: int) -> void:
	DisplayServer.clipboard_set(_server.player_url(_addresses[_selected_address], player))
	_copy[player].text = "已复制"
