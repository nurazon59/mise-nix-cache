package main

import (
	"archive/tar"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const maxCacheBytes = int64(9500000000)
const maxManifestBytes = int64(8388608)

var cacheFile = regexp.MustCompile(`^cache/(nix-cache-info|[a-z0-9]{32}\.narinfo|nar/[A-Za-z0-9+._-]+\.nar(\.(xz|zst|bz2|gz|lz4|br))?)$`)

func extract(r io.Reader, destination string) error {
	if err := os.Mkdir(destination, 0700); err != nil {
		return err
	}
	reader := tar.NewReader(r)
	seen := make(map[string]bool)
	var total int64
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		name := strings.TrimSuffix(header.Name, "/")
		if seen[name] {
			return fmt.Errorf("duplicate archive entry: %q", name)
		}
		seen[name] = true
		if len(seen) > 100000 {
			return fmt.Errorf("too many archive entries")
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if name != "cache" && name != "cache/nar" {
				return fmt.Errorf("unexpected archive directory: %q", name)
			}
			if err := os.MkdirAll(filepath.Join(destination, name), 0700); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			if name != "manifest.json" && !cacheFile.MatchString(name) {
				return fmt.Errorf("unexpected archive file: %q", name)
			}
			if header.Size < 0 || header.Size > maxCacheBytes+maxManifestBytes-total {
				return fmt.Errorf("archive exceeds size limit")
			}
			if name == "manifest.json" && header.Size > maxManifestBytes {
				return fmt.Errorf("manifest exceeds size limit")
			}
			total += header.Size
			path := filepath.Join(destination, name)
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				return err
			}
			file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(file, reader)
			closeErr := file.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		default:
			return fmt.Errorf("unsupported archive entry type for %q", name)
		}
	}
	if !seen["manifest.json"] || !seen["cache/nix-cache-info"] {
		return fmt.Errorf("archive is missing manifest or nix-cache-info")
	}
	return nil
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: extract-cache <archive> <new-destination>")
		os.Exit(2)
	}
	file, err := os.Open(os.Args[1])
	if err == nil {
		defer file.Close()
		err = extract(file, os.Args[2])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
