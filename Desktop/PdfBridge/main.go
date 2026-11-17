package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	pdfcpusign "github.com/agcom/pdfcpu-sign"
	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("missing operation")
	}
	ctx := context.Background()
	switch args[0] {
	case "stamp":
		if len(args) != 8 {
			return fmt.Errorf("usage: stamp input.pdf output.pdf stamp.png x y width page|all")
		}
		x, err := strconv.ParseFloat(args[4], 64)
		if err != nil {
			return err
		}
		y, err := strconv.ParseFloat(args[5], 64)
		if err != nil {
			return err
		}
		width, err := strconv.ParseFloat(args[6], 64)
		if err != nil {
			return err
		}
		if width <= 0 {
			return fmt.Errorf("stamp width must be positive")
		}
		desc := fmt.Sprintf("scale:%.3f abs, pos:bl, off:%.3f %.3f, rot:0", width, x, y)
		wm, err := api.ImageWatermark(ctx, args[3], desc, true, false, types.POINTS, nil)
		if err != nil {
			return err
		}
		var pages []string
		if args[7] != "all" {
			pages = []string{args[7]}
		}
		return api.AddWatermarksFile(ctx, args[1], args[2], pages, wm, nil)
	case "attach":
		if len(args) != 5 {
			return fmt.Errorf("usage: attach stamped.pdf output.pdf original.pdf signature.sig")
		}
		return api.AddAttachmentsFile(ctx, args[1], args[2], []string{args[3], args[4]}, false, nil)
	case "pades":
		return signPades(ctx, args[1:])
	default:
		return fmt.Errorf("unknown operation: %s", args[0])
	}
}

func signPades(ctx context.Context, args []string) error {
	if len(args) != 9 {
		return fmt.Errorf("usage: pades input.pdf output.pdf stamp.png x y width page|all callback-url signer-name")
	}
	x, err := strconv.ParseFloat(args[3], 64)
	if err != nil {
		return err
	}
	y, err := strconv.ParseFloat(args[4], 64)
	if err != nil {
		return err
	}
	width, err := strconv.ParseFloat(args[5], 64)
	if err != nil || width <= 0 {
		return fmt.Errorf("invalid stamp width")
	}
	desc := fmt.Sprintf("scale:%.3f abs, pos:bl, off:%.3f %.3f, rot:0", width, x, y)
	wm, err := api.ImageWatermark(ctx, args[2], desc, true, false, types.POINTS, nil)
	if err != nil {
		return err
	}
	var pages []string
	if args[6] != "all" {
		pages = []string{args[6]}
	}
	stamped, err := os.CreateTemp(filepath.Dir(args[1]), ".stampsign-pades-stamped-*.pdf")
	if err != nil {
		return err
	}
	stampedPath := stamped.Name()
	if err := stamped.Close(); err != nil {
		return err
	}
	defer os.Remove(stampedPath)
	if err := api.AddWatermarksFile(ctx, args[0], stampedPath, pages, wm, nil); err != nil {
		return err
	}

	handler := pdfcpusign.NewExternalCadesDetachedSigHandler(func(byteRange []byte) ([]byte, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, args[7], bytes.NewReader(byteRange))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/octet-stream")
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			message, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
			return nil, fmt.Errorf("CryptoPro signing request failed: %s", strings.TrimSpace(string(message)))
		}
		return io.ReadAll(response.Body)
	})
	signInfo := (&pdfcpusign.SignInfo{
		Type:       pdfcpusign.SignTypeApproval,
		SignerInfo: &pdfcpusign.SignerInfo{Name: args[8], Time: time.Now()},
	}).ToSig()
	return pdfcpusign.SignFile(handler, stampedPath, args[1], signInfo)
}
