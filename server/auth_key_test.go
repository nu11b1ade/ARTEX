package server

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// ARTEX_JWT_KEY_PATH 让容器把签名密钥放到独立卷上：容器重建（keyDir 变化）后
// 仍应读到同一把 key，否则每次镜像更新都会让登录态与 Basic Auth 验证 Cookie 失效。
func TestJWTKeyPathOverrideSurvivesContainerRecreate(t *testing.T) {
	stateDir := t.TempDir()
	keyPath := filepath.Join(stateDir, "state", "jwt.key")
	t.Setenv("ARTEX_JWT_KEY_PATH", keyPath)
	dataDir := t.TempDir()

	first, err := loadOrCreateJWTKey(t.TempDir(), dataDir)
	if err != nil {
		t.Fatalf("first load: %v", err)
	}
	if _, err := os.Stat(keyPath); err != nil {
		t.Fatalf("key not written to override path: %v", err)
	}
	info, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("key mode = %o, want 600", mode)
	}

	// 模拟重建容器：keyDir 换成新目录，override 路径不变。
	second, err := loadOrCreateJWTKey(t.TempDir(), dataDir)
	if err != nil {
		t.Fatalf("second load: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("JWT key changed after keyDir changed; sessions would be invalidated")
	}
}

func TestJWTKeyDefaultPathUnchanged(t *testing.T) {
	keyDir := t.TempDir()
	dataDir := t.TempDir()
	t.Setenv("ARTEX_JWT_KEY_PATH", "")

	first, err := loadOrCreateJWTKey(keyDir, dataDir)
	if err != nil {
		t.Fatalf("first load: %v", err)
	}
	if _, err := os.Stat(filepath.Join(keyDir, jwtKeyFilename)); err != nil {
		t.Fatalf("default key path not used: %v", err)
	}
	second, err := loadOrCreateJWTKey(keyDir, dataDir)
	if err != nil {
		t.Fatalf("second load: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("JWT key changed on reload")
	}
}
