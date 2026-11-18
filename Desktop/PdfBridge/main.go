package main

import (
	"bytes"
	"context"
	"encoding/asn1"
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
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
)

var errNoPadesSignature = fmt.Errorf("no PAdES signature found")

func main() {
	if err := run(os.Args[1:]); err != nil {
		if err == errNoPadesSignature {
			os.Exit(2)
		}
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
	case "extract-pades":
		return extractPadesSignature(ctx, args[1:])
	default:
		return fmt.Errorf("unknown operation: %s", args[0])
	}
}

func extractPadesSignature(ctx context.Context, args []string) error {
	if len(args) != 3 {
		return fmt.Errorf("usage: extract-pades signed.pdf cms.der signed-byte-range.bin")
	}
	pdfBytes, err := os.ReadFile(args[0])
	if err != nil { return err }
	pdfCtx, err := pdfcpu.Read(ctx, bytes.NewReader(pdfBytes), nil)
	if err != nil { return err }
	catalog, err := pdfCtx.Catalog()
	if err != nil { return err }
	acroFormObject, ok := catalog.Find("AcroForm")
	if !ok { return errNoPadesSignature }
	acroForm, err := pdfCtx.DereferenceDict(acroFormObject)
	if err != nil { return errNoPadesSignature }
	fieldsObject, ok := acroForm.Find("Fields")
	if !ok { return errNoPadesSignature }
	fields, err := pdfCtx.DereferenceArray(fieldsObject)
	if err != nil { return errNoPadesSignature }
	var cmsBytes, signedBytes []byte
	for _, field := range fields {
		candidateCMS, candidateBytes, candidateErr := findPadesSignature(pdfCtx, pdfBytes, field, "", 0)
		if candidateErr != nil {
			return candidateErr
		}
		if candidateCMS != nil {
			cmsBytes, signedBytes = candidateCMS, candidateBytes
		}
	}
	if cmsBytes == nil { return errNoPadesSignature }
	if err := os.WriteFile(args[1], cmsBytes, 0600); err != nil { return err }
	return os.WriteFile(args[2], signedBytes, 0600)
}

func findPadesSignature(ctx *model.Context, pdfBytes []byte, field types.Object, inheritedType string, depth int) ([]byte, []byte, error) {
	if depth > 64 { return nil, nil, fmt.Errorf("PDF form field nesting exceeds the supported depth") }
	dict, err := ctx.DereferenceDict(field)
	if err != nil { return nil, nil, nil }
	fieldType := inheritedType
	if name := dict.NameEntry("FT"); name != nil { fieldType = *name }
	if fieldType == "Sig" {
		if value, ok := dict.Find("V"); ok {
			sigDict, err := ctx.DereferenceDict(value)
			if err != nil {
				return nil, nil, fmt.Errorf("cannot read PAdES signature dictionary: %w", err)
			}
			cms, signed, err := signatureContentsAndByteRange(pdfBytes, ctx, sigDict)
			if err != nil {
				return nil, nil, fmt.Errorf("invalid PAdES signature field: %w", err)
			}
			return cms, signed, nil
		}
	}
	if kids, ok := dict.Find("Kids"); ok {
		arr, err := ctx.DereferenceArray(kids)
		if err != nil { return nil, nil, err }
		for _, child := range arr {
			cms, signed, err := findPadesSignature(ctx, pdfBytes, child, fieldType, depth+1)
			if err != nil || cms != nil { return cms, signed, err }
		}
	}
	return nil, nil, nil
}

func signatureContentsAndByteRange(pdfBytes []byte, ctx *model.Context, sigDict types.Dict) ([]byte, []byte, error) {
	contents := sigDict.HexLiteralEntry("Contents")
	if contents == nil { return nil, nil, fmt.Errorf("PDF signature has no Contents") }
	container, err := contents.Bytes()
	if err != nil { return nil, nil, err }
	var raw asn1.RawValue
	if _, err := asn1.Unmarshal(container, &raw); err == nil && len(raw.FullBytes) > 0 { container = raw.FullBytes }
	brObject, ok := sigDict.Find("ByteRange")
	if !ok { return nil, nil, fmt.Errorf("PDF signature has no ByteRange") }
	br, err := ctx.DereferenceArray(brObject)
	if err != nil || len(br) != 4 { return nil, nil, fmt.Errorf("invalid PDF signature ByteRange") }
	values := make([]int64, 4)
	for i, value := range br {
		switch integer := value.(type) {
		case types.Integer:
			values[i] = int64(integer)
		case interface{ String() string }:
			parsed, err := strconv.ParseInt(strings.TrimSpace(integer.String()), 10, 64)
			if err != nil { return nil, nil, fmt.Errorf("invalid PDF signature ByteRange value") }
			values[i] = parsed
		default:
			return nil, nil, fmt.Errorf("invalid PDF signature ByteRange value")
		}
	}
	start1, length1, start2, length2 := values[0], values[1], values[2], values[3]
	if start1 != 0 || length1 < 0 || start2 < 0 || length2 < 0 || start2 > int64(len(pdfBytes)) || length2 > int64(len(pdfBytes))-start2 {
		return nil, nil, fmt.Errorf("PDF signature ByteRange is outside the file")
	}
	if length1 > int64(len(pdfBytes)) || start2 < length1 {
		return nil, nil, fmt.Errorf("PDF signature ByteRange is invalid")
	}
	signed := make([]byte, 0, length1+length2)
	signed = append(signed, pdfBytes[start1:start1+length1]...)
	signed = append(signed, pdfBytes[start2:start2+length2]...)
	return container, signed, nil
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
