extends RefCounted

const DIRECTORY := "user://tls"
const ROOT_CONFIG := """[req]
distinguished_name = name
x509_extensions = authority
prompt = no
[name]
CN = Godot Phone Motion Local CA
[authority]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
"""
const SERVER_CONFIG := """[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = %s
"""

var error := ""
var der := PackedByteArray()
var profile := PackedByteArray()
var _openssl := "openssl"

func setup(addresses: Array[String]) -> TLSOptions:
	if OS.get_name() == "macOS" and FileAccess.file_exists("/usr/bin/openssl"):
		_openssl = "/usr/bin/openssl"
	var directory := ProjectSettings.globalize_path(DIRECTORY)
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		error = "无法创建本地证书目录。"
		return null
	if OS.get_name() != "Windows" and FileAccess.set_unix_permissions(directory,
			FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER) != OK:
		error = "无法保护本地证书目录。"
		return null
	var root := directory.path_join("root.crt")
	var root_key := directory.path_join("root.key")
	var root_config := directory.path_join("root.cnf")
	var server_key := directory.path_join("server.key")
	var certificate := directory.path_join("server.crt")
	var server_config := directory.path_join("server.cnf")
	var request := directory.path_join("server.csr")
	var public_der := directory.path_join("root.der")

	if not FileAccess.file_exists(root) or not FileAccess.file_exists(root_key):
		if not _write(root_config, ROOT_CONFIG) or not _run([
			"req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
			"-config", root_config, "-keyout", root_key, "-out", root
		]):
			return null

	var names := PackedStringArray(["IP:127.0.0.1", "DNS:localhost"])
	for address in addresses:
		if address != "127.0.0.1":
			names.append("IP:" + address)
	if not _write(server_config, SERVER_CONFIG % ",".join(names)):
		return null
	if not _run([
		"req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Godot Phone Motion",
		"-keyout", server_key, "-out", request
	]) or not _run([
		"x509", "-req", "-in", request, "-CA", root, "-CAkey", root_key,
		"-set_serial", "0x" + Crypto.new().generate_random_bytes(16).hex_encode(),
		"-out", certificate, "-days", "30", "-sha256", "-extfile", server_config, "-extensions", "server"
	]) or not _run(["x509", "-in", root, "-outform", "DER", "-out", public_der]):
		return null
	var key := CryptoKey.new()
	var chain := X509Certificate.new()
	der = FileAccess.get_file_as_bytes(public_der)
	if der.is_empty() or key.load(server_key) != OK or chain.load_from_string(
			FileAccess.get_file_as_string(certificate) + FileAccess.get_file_as_string(root)) != OK:
		error = "无法读取生成的本地证书。"
		return null
	profile = _make_profile()
	return TLSOptions.server(key, chain)

func _write(path: String, content: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		error = "无法写入本地证书目录。"
		return false
	file.store_string(content)
	return true

func _run(arguments: PackedStringArray) -> bool:
	var output := []
	if OS.execute(_openssl, arguments, output, true) == 0:
		return true
	error = "无法生成 HTTPS 证书，请确认电脑已安装 OpenSSL。"
	push_error("%s %s" % [error, str(output)])
	return false

func _make_profile() -> PackedByteArray:
	var template := FileAccess.get_file_as_string("res://web/certificate.mobileconfig")
	var id := Marshalls.raw_to_base64(der).sha256_text()
	var profile_id := "%s-%s-%s-%s-%s" % [
		id.substr(0, 8), id.substr(8, 4), id.substr(12, 4), id.substr(16, 4), id.substr(20, 12)]
	var payload_id := "%s-%s-%s-%s-%s" % [
		id.substr(32, 8), id.substr(40, 4), id.substr(44, 4), id.substr(48, 4), id.substr(52, 12)]
	return template.replace("__PROFILE_ID__", profile_id).replace("__PAYLOAD_ID__", payload_id) \
		.replace("__CERTIFICATE__", Marshalls.raw_to_base64(der)).to_utf8_buffer()
