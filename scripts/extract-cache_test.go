package main

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type archiveEntry struct {
	name string
	body string
	kind byte
}

func archive(t *testing.T, entries ...archiveEntry) *bytes.Reader {
	t.Helper()
	var contents bytes.Buffer
	writer := tar.NewWriter(&contents)
	for _, entry := range entries {
		header := &tar.Header{Name: entry.name, Typeflag: entry.kind, Mode: 0600, Size: int64(len(entry.body))}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte(entry.body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return bytes.NewReader(contents.Bytes())
}

func TestExtract(t *testing.T) {
	valid := []archiveEntry{
		{name: "manifest.json", body: "{}"},
		{name: "cache/nix-cache-info", body: "StoreDir: /nix/store\n"},
		{name: "cache/" + strings.Repeat("a", 32) + ".narinfo", body: "narinfo"},
		{name: "cache/nar/example.nar.zst", body: "archive"},
	}
	t.Run("valid cache", func(t *testing.T) {
		dest := filepath.Join(t.TempDir(), "cache")
		if err := extract(archive(t, valid...), dest); err != nil {
			t.Fatal(err)
		}
		if body, err := os.ReadFile(filepath.Join(dest, "cache/nar/example.nar.zst")); err != nil || string(body) != "archive" {
			t.Fatalf("unexpected extracted content: %q, %v", body, err)
		}
	})
	for _, tc := range []struct {
		name    string
		entries []archiveEntry
	}{
		{"path traversal", append(append([]archiveEntry{}, valid...), archiveEntry{name: "../outside", body: "bad"})},
		{"absolute path", append(append([]archiveEntry{}, valid...), archiveEntry{name: "/outside", body: "bad"})},
		{"symlink", append(append([]archiveEntry{}, valid...), archiveEntry{name: "cache/nar/link.nar", kind: tar.TypeSymlink})},
		{"duplicate", append(append([]archiveEntry{}, valid...), valid[0])},
		{"missing manifest", valid[1:]},
		{"unexpected file", append(append([]archiveEntry{}, valid...), archiveEntry{name: "cache/other", body: "bad"})},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dest := filepath.Join(t.TempDir(), "cache")
			if err := extract(archive(t, tc.entries...), dest); err == nil {
				t.Fatal("expected archive to be rejected")
			}
		})
	}
}
