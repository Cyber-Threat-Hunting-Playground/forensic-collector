# Clipboard Content and Metadata Collector

**Author**: Jean-Marc ALBERT (powered by AI)  
**Date**: 2026-02-19  
**Platform**: Windows

---

## Objective

This script collects the current Windows clipboard content and related metadata for investigation and triage.

It captures:
- Text clipboard data
- HTML clipboard data
- RTF clipboard data
- File drop list entries
- Image/audio presence indicators
- Clipboard format inventory

The output follows the same collector pattern used in this repository:
1. Endpoint metadata record (`RecordType = "EndpointInfo"`)
2. Clipboard record (`RecordType = "ClipboardInfo"`)

---

## Script

- `collect_clipboard_content_and_metadata.ps1`

---

## Requirements

- **Platform**: Windows
- **PowerShell**: 5.0 or later
- **Dependencies**: None (built-in PowerShell/.NET only)
- **Permissions**: Standard user permissions are usually enough, but access depends on session context

---

## Collection Details

The script uses built-in technologies only:
- `System.Windows.Forms.Clipboard` for clipboard data access
- STA runspace for reliable clipboard reads across host contexts
- Native Win32 call (`GetClipboardSequenceNumber`) for sequence tracking
- Built-in .NET SHA-256 for content hashes

Collected clipboard metadata includes:
- Available clipboard formats and count
- Text length, SHA-256, and text preview (first 1000 chars)
- HTML length, SHA-256, and `SourceURL` extraction when present
- RTF length and SHA-256
- File list plus per-file metadata (exists/size/last modified)
- Image presence and dimensions
- Audio presence
- Read success/error status

---

## Output Files

The script writes:
- JSON inventory
- Log file

Output location depends on execution context:

- **RemoteOps** (`$Env:S1_OUTPUT_DIR_PATH`)
  - `Clipboard_Content_Metadata_Inventory.json`
  - `Clipboard_Content_Metadata_Inventory.log`
- **Local execution** (`$Env:TEMP`)
  - `Clipboard_Content_Metadata_Inventory.json`
  - `Clipboard_Content_Metadata_Inventory.log`
- **Local execution with `-AddDate`** (`$Env:TEMP`)
  - `Clipboard_Content_Metadata_Inventory_<timestamp>.json`
  - `Clipboard_Content_Metadata_Inventory_<timestamp>.log`

JSON is written as UTF-8 without BOM.

---

## Output Structure

### Endpoint Record Fields

- `RecordType`
- `EndpointHostname`
- `EndpointOS`
- `EndpointOSVersion`
- `EndpointOSBuild`
- `EndpointCollectionDate`

### Clipboard Record Fields

- `RecordType`
- `ClipboardCollectionDate`
- `ClipboardSequenceNumber`
- `ClipboardReadSuccess`
- `ClipboardReadError`
- `ClipboardAvailableFormats`
- `ClipboardFormatCount`
- `ClipboardContainsText`
- `ClipboardTextLength`
- `ClipboardTextSha256`
- `ClipboardTextPreview`
- `ClipboardContainsHtml`
- `ClipboardHtmlLength`
- `ClipboardHtmlSha256`
- `ClipboardHtmlSourceUrl`
- `ClipboardContainsRtf`
- `ClipboardRtfLength`
- `ClipboardRtfSha256`
- `ClipboardContainsFileDropList`
- `ClipboardFileCount`
- `ClipboardFiles`
- `ClipboardFileDetails`
- `ClipboardContainsImage`
- `ClipboardImageWidth`
- `ClipboardImageHeight`
- `ClipboardImagePixelFormat`
- `ClipboardContainsAudio`

---

## Example Usage

```powershell
powershell -ExecutionPolicy Bypass -File ".\collect_clipboard_content_and_metadata.ps1"
```

To include a timestamp in the output file names:

```powershell
powershell -ExecutionPolicy Bypass -File ".\collect_clipboard_content_and_metadata.ps1" -AddDate
```

---

## Notes and Limitations

- Clipboard data is session-scoped; running as SYSTEM/non-interactive context may return limited or empty data.
- Very large clipboard content is hashed and length-tracked; text preview is truncated to 1000 characters.
- Clipboard content can change at any time; this is a point-in-time snapshot.


