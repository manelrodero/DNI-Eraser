<# 
 .SYNOPSIS
  Photo Eraser & Watermark Tool
  Select rectangular regions to erase and apply watermark text to images.

 .DESCRIPTION
  Click & drag to select areas → erase (fill with color) → add watermark.
  All processing is local. No data is sent anywhere.

 .USAGE
  Right-click the .ps1 file → "Run with PowerShell"
  OR from a terminal:  powershell -File foto_editor.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── State ──────────────────────────────────────────────────────────────────
$script:originalImage  = $null  # [System.Drawing.Bitmap]
$script:workImage      = $null  # [System.Drawing.Bitmap]
$script:rects          = @()    # [System.Drawing.Rectangle[]]
$script:scaleX         = 1.0
$script:scaleY         = 1.0
$script:isDragging     = $false
$script:dragStart      = $null
$script:dragEnd        = $null
$script:hasImage       = $false

# ── Helper: open image ─────────────────────────────────────────────────────
function Open-Image {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = "Select an image"
    $dlg.Filter = "Image files|*.png;*.jpg;*.jpeg;*.bmp;*.tiff;*.webp|All files|*.*"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $path = $dlg.FileName
    try {
        $img = [System.Drawing.Image]::FromFile($path)
        $script:originalImage = New-Object System.Drawing.Bitmap $img
        $img.Dispose()
        $script:workImage = New-Object System.Drawing.Bitmap $script:originalImage
        $script:rects = @()
        $script:hasImage = $true
        Update-Canvas
        $listBox.Items.Clear()
        $global:imagePath = $path
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not open image: $_", "Error")
    }
}

# ── Helper: save image ────────────────────────────────────────────────────
function Save-Image {
    if (-not $script:hasImage) {
        [System.Windows.Forms.MessageBox]::Show("No image to save.", "Warning")
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title  = "Save image as"
    $dlg.Filter = "PNG|*.png|JPEG|*.jpg|All files|*.*"
    $dlg.DefaultExt = "png"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $path  = $dlg.FileName
    $ext   = [System.IO.Path]::GetExtension($path).ToLower()
    $fmt   = if ($ext -eq '.jpg' -or $ext -eq '.jpeg') {
        [System.Drawing.Imaging.ImageFormat]::Jpeg
    } else {
        [System.Drawing.Imaging.ImageFormat]::Png
    }
    try {
        $script:workImage.Save($path, $fmt)
        [System.Windows.Forms.MessageBox]::Show("Saved to: $path", "Done")
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not save: $_", "Error")
    }
}

# ── Convert rect display → original coords ─────────────────────────────────
function Convert-RectToOriginal([System.Drawing.Rectangle]$r) {
    $x = [int]($r.X / $script:scaleX)
    $y = [int]($r.Y / $script:scaleY)
    $w = [int]($r.Width  / $script:scaleX)
    $h = [int]($r.Height / $script:scaleY)
    $ow = $script:originalImage.Width
    $oh = $script:originalImage.Height
    $x = [Math]::Max(0, [Math]::Min($x, $ow-1))
    $y = [Math]::Max(0, [Math]::Min($y, $oh-1))
    $w = [Math]::Max(1, [Math]::Min($w, $ow-$x))
    $h = [Math]::Max(1, [Math]::Min($h, $oh-$y))
    return [System.Drawing.Rectangle]::new($x, $y, $w, $h)
}

# ── Update canvas picture box ──────────────────────────────────────────────
function Update-Canvas {
    $pb = $canvasPictureBox
    if (-not $script:hasImage -or $null -eq $script:workImage) {
        $pb.Image = $null; return
    }
    $cw = $pb.ClientSize.Width
    $ch = $pb.ClientSize.Height
    if ($cw -le 0 -or $ch -le 0) { return }

    $iw = $script:workImage.Width
    $ih = $script:workImage.Height

    # Fit to canvas (no upscale)
    $s = [Math]::Min($cw / $iw, $ch / $ih)
    if ($s -gt 1.0) { $s = 1.0 }
    $script:scaleX = $s
    $script:scaleY = $s
    $nw = [int]($iw * $s)
    $nh = [int]($ih * $s)

    $bmp = New-Object System.Drawing.Bitmap $cw, $ch
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(45,45,45))
    $xOff = ($cw - $nw) / 2
    $yOff = ($ch - $nh) / 2
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($script:workImage, $xOff, $yOff, $nw, $nh)

    # Draw selection rectangles
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 68, 68), 2.0)
    $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $font = New-Object System.Drawing.Font ("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $brush = [System.Drawing.Brushes]::White
    foreach ($r in $script:rects) {
        $dx = $r.X * $s + $xOff
        $dy = $r.Y * $s + $yOff
        $dw = $r.Width  * $s
        $dh = $r.Height * $s
        $g.DrawRectangle($pen, $dx, $dy, $dw, $dh)
        $g.DrawString(" $($r.Width)x$($r.Height) ", $font, $brush, $dx+2, $dy+2)
    }

    # Draw drag preview
    if ($script:isDragging -and $script:dragStart -and $script:dragEnd) {
        $x1 = [Math]::Min($script:dragStart.X, $script:dragEnd.X)
        $y1 = [Math]::Min($script:dragStart.Y, $script:dragEnd.Y)
        $x2 = [Math]::Max($script:dragStart.X, $script:dragEnd.X)
        $y2 = [Math]::Max($script:dragStart.Y, $script:dragEnd.Y)
        $dragPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 200, 50), 2.0)
        $dragPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $g.DrawRectangle($dragPen, $x1, $y1, $x2-$x1, $y2-$y1)
        $dragPen.Dispose()
    }

    $pen.Dispose()
    $g.Dispose()

    if ($pb.Image) { $pb.Image.Dispose() }
    $pb.Image = $bmp
}

# ── Apply effects ──────────────────────────────────────────────────────────
function Apply-Effects {
    if (-not $script:hasImage) {
        [System.Windows.Forms.MessageBox]::Show("Open an image first.", "Warning"); return
    }
    $txt = $watermarkText.Text.Trim()
    if (-not $txt) {
        [System.Windows.Forms.MessageBox]::Show("Enter watermark text.", "Warning"); return
    }
    if ($script:rects.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No areas selected to erase.", "Warning"); return
    }

    $bmp = New-Object System.Drawing.Bitmap $script:originalImage
    $g   = [System.Drawing.Graphics]::FromImage($bmp)

    # ── Erase selections ───────────────────────────────────────────────────
    $fillColor = $fillColorBtn.BackColor
    $brush     = New-Object System.Drawing.SolidBrush $fillColor
    $erased    = 0
    foreach ($r in $script:rects) {
        $orig = Convert-RectToOriginal $r
        if ($orig.Width -gt 0 -and $orig.Height -gt 0) {
            $g.FillRectangle($brush, $orig)
            $erased++
        }
    }
    $brush.Dispose()

    # ── Watermark ──────────────────────────────────────────────────────────
    $fontSize = $fontSizeTrack.Value
    $fontObj  = New-Object System.Drawing.Font ("Arial", $fontSize, [System.Drawing.FontStyle]::Bold)
    $opacity  = [int]($opacityTrack.Value)  # 0-100
    $alpha    = [int]($opacity * 2.55)      # 0-255
    $wmColor  = $watermarkColorBtn.BackColor
    $wmColorA = [System.Drawing.Color]::FromArgb($alpha, $wmColor.R, $wmColor.G, $wmColor.B)
    $wmBrush  = New-Object System.Drawing.SolidBrush $wmColorA

    $posVal = $posCombo.SelectedItem
    $sf     = $g.MeasureString($txt, $fontObj)
    $tw     = $sf.Width
    $th     = $sf.Height
    $iw     = $bmp.Width
    $ih     = $bmp.Height
    $margin = [int]($fontSize * 0.5)

    if ($posVal -eq "diagonal-tiled") {
        $pad  = [int]($fontSize * 1.5)
        $cell = [int]([Math]::Max($tw, $th) + $pad)
        $tileBmp = New-Object System.Drawing.Bitmap $cell, $cell
        $tg = [System.Drawing.Graphics]::FromImage($tileBmp)
        $tg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $tg.DrawString($txt, $fontObj, $wmBrush,
            ($cell-$tw)/2, ($cell-$th)/2)
        $tg.Dispose()

        $rotBmp = New-Object System.Drawing.Bitmap $cell, $cell
        $rg = [System.Drawing.Graphics]::FromImage($rotBmp)
        $rg.TranslateTransform($cell/2, $cell/2)
        $rg.RotateTransform(35)
        $rg.TranslateTransform(-$cell/2, -$cell/2)
        $rg.DrawImage($tileBmp, 0, 0)
        $rg.Dispose()
        $tileBmp.Dispose()

        $tw3 = $rotBmp.Width
        $th3 = $rotBmp.Height
        for ($y = -$th3; $y -lt $ih + $th3; $y += $th3) {
            for ($x = -$tw3; $x -lt $iw + $tw3; $x += $tw3) {
                $g.DrawImage($rotBmp, $x, $y)
            }
        }
        $rotBmp.Dispose()
    } elseif ($posVal -eq "tiled") {
        $stepY = [int]($th + $fontSize * 2)
        $stepX = [int]($tw + $fontSize * 2.5)
        for ($y = $margin; $y -lt $ih; $y += $stepY) {
            for ($x = $margin; $x -lt $iw; $x += $stepX) {
                $g.DrawString($txt, $fontObj, $wmBrush, $x, $y)
            }
        }
    } else {
        $placements = @{
            "top-left"      = @($margin, $margin)
            "top-right"     = @($iw - $tw - $margin, $margin)
            "bottom-left"   = @($margin, $ih - $th - $margin)
            "bottom-right"  = @($iw - $tw - $margin, $ih - $th - $margin)
            "center"        = @(($iw - $tw)/2, ($ih - $th)/2)
        }
        if (-not $placements.ContainsKey($posVal)) { $posVal = "bottom-right" }
        $xy = $placements[$posVal]
        $g.DrawString($txt, $fontObj, $wmBrush, $xy[0], $xy[1])
    }

    $fontObj.Dispose()
    $wmBrush.Dispose()
    $g.Dispose()

    $script:workImage.Dispose()
    $script:workImage = $bmp
    $script:rects = @()
    $listBox.Items.Clear()
    Update-Canvas
    [System.Windows.Forms.MessageBox]::Show("Done! $erased region(s) erased, watermark applied.", "Complete")
}

# ── Clear all selections ───────────────────────────────────────────────────
function Clear-Selections {
    $script:rects = @()
    $listBox.Items.Clear()
    Update-Canvas
}

# ── Remove selected from list ──────────────────────────────────────────────
function Remove-Selected {
    if ($listBox.SelectedIndex -lt 0) { return }
    $idx = $listBox.SelectedIndex
    $script:rects = @($script:rects[0..($idx-1)] + $script:rects[($idx+1)..($script:rects.Count-1)])
    $listBox.Items.RemoveAt($idx)
    if ($listBox.Items.Count -gt 0) {
        $listBox.SelectedIndex = [Math]::Min($idx, $listBox.Items.Count-1)
    }
    Update-Canvas
}

# ═══════════════════════════════════════════════════════════════════════════
# UI BUILD
# ═══════════════════════════════════════════════════════════════════════════

$form = New-Object System.Windows.Forms.Form
$form.Text          = "Photo Eraser & Watermark"
$form.Size          = New-Object System.Drawing.Size(1200, 800)
$form.MinimumSize   = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = "CenterScreen"
$form.Icon          = $null

# ── Layout ─────────────────────────────────────────────────────────────────
$tableLayout = New-Object System.Windows.Forms.TableLayoutPanel
$tableLayout.Dock       = "Fill"
$tableLayout.ColumnCount = 2
$tableLayout.RowCount    = 1

# Column 0: canvas (left, fills remaining space)
# Column 1: controls (fixed 260px)
$tableLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle "Percent" 100))
$tableLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle "Absolute" 270))
$tableLayout.Padding = New-Object System.Windows.Forms.Padding(6)

# ── Canvas ─────────────────────────────────────────────────────────────────
$canvasPictureBox = New-Object System.Windows.Forms.PictureBox
$canvasPictureBox.Dock = "Fill"
$canvasPictureBox.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$canvasPictureBox.SizeMode = "Normal"
$canvasPictureBox.Cursor = "Cross"

# Mouse events for rectangle selection
$canvasPictureBox.Add_MouseDown({
    $script:dragStart  = New-Object System.Drawing.Point $_.X, $_.Y
    $script:dragEnd    = $script:dragStart
    $script:isDragging = $true
})
$canvasPictureBox.Add_MouseMove({
    if ($script:isDragging) {
        $script:dragEnd = New-Object System.Drawing.Point $_.X, $_.Y
        Update-Canvas
    }
})
$canvasPictureBox.Add_MouseUp({
    if (-not $script:isDragging) { return }
    $script:isDragging = $false

    # Convert screen coords → image coords
    $pb = $canvasPictureBox
    $cw = $pb.ClientSize.Width
    $ch = $pb.ClientSize.Height
    $s  = $script:scaleX
    if ($s -le 0) { $s = 1.0 }
    $nw = [int]($script:workImage.Width  * $s)
    $nh = [int]($script:workImage.Height * $s)
    $xOff = ($cw - $nw) / 2
    $yOff = ($ch - $nh) / 2

    $x1 = [int]([Math]::Min($script:dragStart.X, $script:dragEnd.X) - $xOff)
    $y1 = [int]([Math]::Min($script:dragStart.Y, $script:dragEnd.Y) - $yOff)
    $x2 = [int]([Math]::Max($script:dragStart.X, $script:dragEnd.X) - $xOff)
    $y2 = [int]([Math]::Max($script:dragStart.Y, $script:dragEnd.Y) - $yOff)

    # Clamp
    $x1 = [Math]::Max(0, [Math]::Min($x1, $nw))
    $y1 = [Math]::Max(0, [Math]::Min($y1, $nh))
    $x2 = [Math]::Max(0, [Math]::Min($x2, $nw))
    $y2 = [Math]::Max(0, [Math]::Min($y2, $nh))

    $w = $x2 - $x1
    $h = $y2 - $y1
    if ($w -gt 5 -and $h -gt 5) {
        $r = New-Object System.Drawing.Rectangle $x1, $y1, $w, $h
        $script:rects += $r
        $listBox.Items.Add("$($r.Width)×$($r.Height)  at $x1,$y1")
        $listBox.SelectedIndex = $listBox.Items.Count - 1
    }
    Update-Canvas
})

# Handle resize
$canvasPictureBox.Add_Resize({ if ($script:hasImage) { Update-Canvas } })

$tableLayout.Controls.Add($canvasPictureBox, 0, 0)

# ── Control Panel ──────────────────────────────────────────────────────────
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.Width = 270

$yPos = 0
$ctrlGap = 4
$groupGap = 12

# Helper to add a label
function Add-Label($text, $bold=$false) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text    = $text
    $lbl.Location = New-Object System.Drawing.Point(0, $yPos)
    $lbl.AutoSize = $true
    if ($bold) { $lbl.Font = New-Object System.Drawing.Font ("Segoe UI", 10, [System.Drawing.FontStyle]::Bold) }
    $panel.Controls.Add($lbl)
    $yPos += $lbl.Height + 2
    return $lbl
}

# Helper to add a button
function Add-Button($text, $width=$null, $height=$null) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = New-Object System.Drawing.Point(0, $yPos)
    if ($width)  { $btn.Width  = $width  } else { $btn.Width  = $panel.Width - 10 }
    if ($height) { $btn.Height = $height } else { $btn.Height = 26 }
    $panel.Controls.Add($btn)
    $yPos += $btn.Height + 3
    return $btn
}

# ── Image section ──────────────────────────────────────────────────────────
Add-Label "Image" $true
$yPos += 2
$openBtn = Add-Button "Open Image"
$openBtn.Add_Click({ Open-Image })
$saveBtn = Add-Button "Save Result"
$saveBtn.Add_Click({ Save-Image })

$yPos += $groupGap

# ── Selections section ─────────────────────────────────────────────────────
Add-Label "Selections" $true
$yPos += 2
$clearBtn = Add-Button "Clear All"
$clearBtn.Add_Click({ Clear-Selections })

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Location = New-Object System.Drawing.Point(0, $yPos)
$listBox.Width    = $panel.Width - 10
$listBox.Height   = 90
$panel.Controls.Add($listBox)
$yPos += $listBox.Height + 3

$removeBtn = Add-Button "Remove Selected"
$removeBtn.Add_Click({ Remove-Selected })

$yPos += $groupGap

# ── Erase section ──────────────────────────────────────────────────────────
Add-Label "Erase Method" $true
$yPos += 2
$fillRadio = New-Object System.Windows.Forms.RadioButton
$fillRadio.Text      = "Fill Color"
$fillRadio.Location  = New-Object System.Drawing.Point(5, $yPos)
$fillRadio.AutoSize  = $true
$fillRadio.Checked   = $true
$panel.Controls.Add($fillRadio)
$yPos += $fillRadio.Height + 2

$fillColorBtn = New-Object System.Windows.Forms.Button
$fillColorBtn.Text = "Choose Fill Color"
$fillColorBtn.Location = New-Object System.Drawing.Point(20, $yPos)
$fillColorBtn.Width    = $panel.Width - 30
$fillColorBtn.Height   = 24
$fillColorBtn.BackColor = [System.Drawing.Color]::White
$fillColorBtn.Add_Click({
    $cd = New-Object System.Windows.Forms.ColorDialog
    if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $fillColorBtn.BackColor = $cd.Color
    }
})
$panel.Controls.Add($fillColorBtn)
$yPos += $fillColorBtn.Height + $groupGap

# ── Watermark section ──────────────────────────────────────────────────────
Add-Label "Watermark" $true
$yPos += 2

$watermarkText = New-Object System.Windows.Forms.TextBox
$watermarkText.Text     = "CONFIDENCIAL"
$watermarkText.Location = New-Object System.Drawing.Point(0, $yPos)
$watermarkText.Width    = $panel.Width - 10
$panel.Controls.Add($watermarkText)
$yPos += $watermarkText.Height + 3

# Font Size
$fsLbl = New-Object System.Windows.Forms.Label
$fsLbl.Text = "Font Size: 36"
$fsLbl.Location = New-Object System.Drawing.Point(0, $yPos)
$fsLbl.AutoSize = $true
$panel.Controls.Add($fsLbl)
$yPos += $fsLbl.Height + 1

$fontSizeTrack = New-Object System.Windows.Forms.TrackBar
$fontSizeTrack.Location   = New-Object System.Drawing.Point(0, $yPos)
$fontSizeTrack.Width      = $panel.Width - 10
$fontSizeTrack.Minimum    = 10
$fontSizeTrack.Maximum    = 200
$fontSizeTrack.Value      = 36
$fontSizeTrack.TickFrequency = 10
$fontSizeTrack.Height     = 36
$fontSizeTrack.Add_Scroll({
    $fsLbl.Text = "Font Size: $($this.Value)"
})
$panel.Controls.Add($fontSizeTrack)
$yPos += $fontSizeTrack.Height + 1

# Opacity
$opLbl = New-Object System.Windows.Forms.Label
$opLbl.Text = "Opacity: 40%"
$opLbl.Location = New-Object System.Drawing.Point(0, $yPos)
$opLbl.AutoSize = $true
$panel.Controls.Add($opLbl)
$yPos += $opLbl.Height + 1

$opacityTrack = New-Object System.Windows.Forms.TrackBar
$opacityTrack.Location   = New-Object System.Drawing.Point(0, $yPos)
$opacityTrack.Width      = $panel.Width - 10
$opacityTrack.Minimum    = 0
$opacityTrack.Maximum    = 100
$opacityTrack.Value      = 40
$opacityTrack.TickFrequency = 10
$opacityTrack.Height     = 36
$opacityTrack.Add_Scroll({
    $opLbl.Text = "Opacity: $($this.Value)%"
})
$panel.Controls.Add($opacityTrack)
$yPos += $opacityTrack.Height + 1

# Position
$posLbl = New-Object System.Windows.Forms.Label
$posLbl.Text = "Position:"
$posLbl.Location = New-Object System.Drawing.Point(0, $yPos)
$posLbl.AutoSize = $true
$panel.Controls.Add($posLbl)
$yPos += $posLbl.Height + 1

$posCombo = New-Object System.Windows.Forms.ComboBox
$posCombo.Location     = New-Object System.Drawing.Point(0, $yPos)
$posCombo.Width        = $panel.Width - 10
$posCombo.DropDownStyle = "DropDownList"
$posCombo.Items.AddRange(@(
    "top-left", "top-right", "bottom-left", "bottom-right",
    "center", "tiled", "diagonal-tiled"
))
$posCombo.SelectedIndex = 6  # diagonal-tiled
$panel.Controls.Add($posCombo)
$yPos += $posCombo.Height + 3

# Watermark Color
$wmColorLbl = New-Object System.Windows.Forms.Label
$wmColorLbl.Text = "Color:"
$wmColorLbl.Location = New-Object System.Drawing.Point(0, $yPos)
$wmColorLbl.AutoSize = $true
$panel.Controls.Add($wmColorLbl)
$yPos += $wmColorLbl.Height + 1

$watermarkColorBtn = New-Object System.Windows.Forms.Button
$watermarkColorBtn.Text = "Choose Color"
$watermarkColorBtn.Location = New-Object System.Drawing.Point(0, $yPos)
$watermarkColorBtn.Width    = $panel.Width - 10
$watermarkColorBtn.Height   = 24
$watermarkColorBtn.BackColor = [System.Drawing.Color]::White
$watermarkColorBtn.Add_Click({
    $cd = New-Object System.Windows.Forms.ColorDialog
    if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $watermarkColorBtn.BackColor = $cd.Color
    }
})
$panel.Controls.Add($watermarkColorBtn)
$yPos += $watermarkColorBtn.Height + $groupGap

# ── Apply ──────────────────────────────────────────────────────────────────
$applyBtn = New-Object System.Windows.Forms.Button
$applyBtn.Text     = "APPLY EFFECTS"
$applyBtn.Location = New-Object System.Drawing.Point(0, $yPos)
$applyBtn.Width    = $panel.Width - 10
$applyBtn.Height   = 32
$applyBtn.Font     = New-Object System.Drawing.Font ("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$applyBtn.Add_Click({ Apply-Effects })
$panel.Controls.Add($applyBtn)

# Allow scrolling if content overflows
$panel.AutoScroll = $true

$tableLayout.Controls.Add($panel, 1, 0)

$form.Controls.Add($tableLayout)

# ── Keyboard shortcuts ─────────────────────────────────────────────────────
$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq 'O') { Open-Image; $_.SuppressKeyPress = $true }
    if ($_.Control -and $_.KeyCode -eq 'S') { Save-Image;  $_.SuppressKeyPress = $true }
})
$form.KeyPreview = $true

# ── Run ────────────────────────────────────────────────────────────────────
[void]$form.ShowDialog()
