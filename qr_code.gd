extends RefCounted

# QR version 3-L in byte mode. One block holds 55 data and 15 correction bytes.
# The longest IPv4 pairing URL fits within the 53-byte payload limit.
const SIZE := 29
const DATA_BYTES := 55
const ECC_BYTES := 15
const QUIET_ZONE := 4

var _modules := PackedByteArray()
var _reserved := PackedByteArray()

func make_texture(url: String) -> ImageTexture:
	var payload := url.to_utf8_buffer()
	assert(payload.size() <= 53)
	_modules.resize(SIZE * SIZE)
	_reserved.resize(SIZE * SIZE)
	_modules.fill(0)
	_reserved.fill(0)
	_draw_patterns()
	_draw_data(_encode(payload))
	var dimension := SIZE + 2 * QUIET_ZONE
	var qr := Image.create(dimension, dimension, false, Image.FORMAT_RGB8)
	qr.fill(Color.WHITE)
	for y in range(SIZE):
		for x in range(SIZE):
			if _modules[y * SIZE + x]:
				qr.set_pixel(x + QUIET_ZONE, y + QUIET_ZONE, Color.BLACK)
	return ImageTexture.create_from_image(qr)

func _draw_patterns() -> void:
	for index in range(SIZE):
		_set_pattern(6, index, index % 2 == 0)
		_set_pattern(index, 6, index % 2 == 0)
	_draw_finder(3, 3)
	_draw_finder(SIZE - 4, 3)
	_draw_finder(3, SIZE - 4)
	for y in range(-2, 3):
		for x in range(-2, 3):
			_set_pattern(22 + x, 22 + y, maxi(absi(x), absi(y)) != 1)
	# Format bits for error correction level L and mask pattern 0.
	var format := 0x77c4
	for index in range(6):
		_set_pattern(8, index, (format >> index) & 1)
	_set_pattern(8, 7, (format >> 6) & 1)
	_set_pattern(8, 8, (format >> 7) & 1)
	_set_pattern(7, 8, (format >> 8) & 1)
	for index in range(9, 15):
		_set_pattern(14 - index, 8, (format >> index) & 1)
	for index in range(8):
		_set_pattern(SIZE - 1 - index, 8, (format >> index) & 1)
	for index in range(8, 15):
		_set_pattern(8, SIZE - 15 + index, (format >> index) & 1)
	_set_pattern(8, SIZE - 8, true)

func _draw_finder(center_x: int, center_y: int) -> void:
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var x := center_x + dx
			var y := center_y + dy
			if x >= 0 and x < SIZE and y >= 0 and y < SIZE:
				var distance := maxi(absi(dx), absi(dy))
				_set_pattern(x, y, distance != 2 and distance != 4)

func _set_pattern(x: int, y: int, dark: bool) -> void:
	var index := y * SIZE + x
	_modules[index] = int(dark)
	_reserved[index] = 1

func _draw_data(words: PackedByteArray) -> void:
	var bit_index := 0
	var right := SIZE - 1
	var upwards := true
	while right > 0:
		if right == 6:
			right -= 1
		for row in range(SIZE):
			var y := SIZE - 1 - row if upwards else row
			for column in range(2):
				var x := right - column
				var index := y * SIZE + x
				if _reserved[index]:
					continue
				var bit := 0
				if bit_index < words.size() * 8:
					@warning_ignore("integer_division")
					bit = (words[bit_index / 8] >> (7 - bit_index % 8)) & 1
				_modules[index] = bit ^ int((x + y) % 2 == 0)
				bit_index += 1
		upwards = not upwards
		right -= 2

func _encode(payload: PackedByteArray) -> PackedByteArray:
	var bits := PackedByteArray()
	_append_bits(bits, 4, 4)
	_append_bits(bits, payload.size(), 8)
	for byte in payload:
		_append_bits(bits, byte, 8)
	_append_bits(bits, 0, 4)
	var data := PackedByteArray()
	for offset in range(0, bits.size(), 8):
		var byte := 0
		for bit in range(8):
			byte = (byte << 1) | bits[offset + bit]
		data.append(byte)
	var pad := 0xec
	while data.size() < DATA_BYTES:
		data.append(pad)
		pad ^= 0xec ^ 0x11
	return data + _correction(data)

func _append_bits(bits: PackedByteArray, value: int, count: int) -> void:
	for shift in range(count - 1, -1, -1):
		bits.append((value >> shift) & 1)

func _correction(data: PackedByteArray) -> PackedByteArray:
	var polynomial := PackedByteArray([1])
	var root := 1
	for degree in range(ECC_BYTES):
		polynomial.append(0)
		for index in range(polynomial.size() - 1, 0, -1):
			polynomial[index] ^= _multiply(polynomial[index - 1], root)
		root = _multiply(root, 2)
	var remainder := data.duplicate()
	remainder.resize(DATA_BYTES + ECC_BYTES)
	for offset in range(DATA_BYTES):
		var factor := remainder[offset]
		for coefficient in range(1, polynomial.size()):
			remainder[offset + coefficient] ^= _multiply(polynomial[coefficient], factor)
	return remainder.slice(DATA_BYTES)

func _multiply(left: int, right: int) -> int:
	var product := 0
	while right > 0:
		if right & 1:
			product ^= left
		right >>= 1
		left <<= 1
		if left & 256:
			left ^= 0x11d
	return product
