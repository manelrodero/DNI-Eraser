<# 
 .SYNOPSIS
  Photo Eraser & Watermark Tool - Privacy Edition 2026 (v7)
#>

# Forzar codificación UTF-8 en la consola para evitar fallos de acentos
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Localización Robusta del Archivo de Configuración ──────────────────────
$script:scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
if (-not $script:scriptPath -or -not (Test-Path $script:scriptPath -PathType Container)) { 
    $script:scriptPath = [System.IO.Directory]::GetCurrentDirectory() 
}

$script:configFile = Join-Path $script:scriptPath "session_config.ini"

# Validar si tenemos permisos de escritura; si no, redirigir a Mis Documentos
try {
    $testFile = Join-Path $script:scriptPath "perm_test.tmp"
    [System.IO.File]::WriteAllText($testFile, "test")
    [System.IO.File]::Delete($testFile)
} catch {
    $docFolder = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments)
    $script:scriptPath = Join-Path $docFolder "EditorDNI"
    if (-not (Test-Path $script:scriptPath)) { [void](New-Item -ItemType Directory -Path $script:scriptPath -Force) }
    $script:configFile = Join-Path $script:scriptPath "session_config.ini"
}

# ── Estado Global Extendido ────────────────────────────────────────────────
$script:docs = @{
    "Frontal" = @{ original = $null; work = $null; rects = @(); hasImage = $false; path = $null }
    "Trasera" = @{ original = $null; work = $null; rects = @(); hasImage = $false; path = $null }
}
$script:currentTab   = "Frontal"
$script:isDragging   = $false
$script:dragStart    = $null
$script:dragEnd      = $null

$script:viewParams = @{
    "Frontal" = @{ scale = 1.0; xOffset = 0; yOffset = 0 }
    "Trasera" = @{ scale = 1.0; xOffset = 0; yOffset = 0 }
}

# ── Funciones de Conversión de Coordenadas ─────────────────────────────────

function Get-CurrentDoc { return $script:docs[$script:currentTab] }

function Convert-RectToOriginal([System.Drawing.Rectangle]$r, $tabName) {
    $doc = $script:docs[$tabName]
    $vp  = $script:viewParams[$tabName]
    if ($vp.scale -le 0 -or -not $doc.hasImage) { return $r }
    
    $x = [int](($r.X - $vp.xOffset) / $vp.scale)
    $y = [int](($r.Y - $vp.yOffset) / $vp.scale)
    $w = [int]($r.Width / $vp.scale)
    $h = [int]($r.Height / $vp.scale)
    
    $ow = $doc.original.Width
    $oh = $doc.original.Height
    
    $x = [Math]::Max(0, [Math]::Min($x, $ow - 1))
    $y = [Math]::Max(0, [Math]::Min($y, $oh - 1))
    $w = [Math]::Max(1, [Math]::Min($w, $ow - $x))
    $h = [Math]::Max(1, [Math]::Min($h, $oh - $y))
    return [System.Drawing.Rectangle]::new($x, $y, $w, $h)
}

# ── Procesamiento de Filtros Gráficos (Escala de Grises) ───────────────────

function Convert-ToGrayscale([System.Drawing.Bitmap]$originalBmp) {
    $grayBmp = New-Object System.Drawing.Bitmap $originalBmp.Width, $originalBmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $originalBmp.Width, $originalBmp.Height
    
    $bmpDataOrig = $originalBmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
    $bmpDataGray = $grayBmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
    
    $size = [Math]::Abs($bmpDataOrig.Stride) * $originalBmp.Height
    $buffer = New-Object byte[] $size
    
    [System.Runtime.InteropServices.Marshal]::Copy($bmpDataOrig.Scan0, $buffer, 0, $size)
    for ($i = 0; $i -lt $size; $i += 4) {
        $gray = [byte](0.114 * $buffer[$i] + 0.587 * $buffer[$i+1] + 0.299 * $buffer[$i+2])
        $buffer[$i]   = $gray
        $buffer[$i+1] = $gray
        $buffer[$i+2] = $gray
    }
    [System.Runtime.InteropServices.Marshal]::Copy($buffer, 0, $bmpDataGray.Scan0, $size)
    
    $originalBmp.UnlockBits($bmpDataOrig)
    $grayBmp.UnlockBits($bmpDataGray)
    return $grayBmp
}

# ── Motores de Interfaz y Carga de Archivos ────────────────────────────────

function Open-Image-Path($path, $tabName) {
    if (-not (Test-Path $path)) { return $false }
    try {
        $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        $img = [System.Drawing.Image]::FromStream($stream)
        $stream.Close(); $stream.Dispose()

        $doc = $script:docs[$tabName]
        if ($doc.original) { $doc.original.Dispose() }
        if ($doc.work) { $doc.work.Dispose() }

        $doc.original = New-Object System.Drawing.Bitmap $img
        $doc.work     = New-Object System.Drawing.Bitmap $doc.original
        $img.Dispose()
        
        $doc.hasImage = $true
        $doc.path     = $path
        return $true
    } catch {
        return $false
    }
}

function Open-Image {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = "Seleccionar Imagen ($script:currentTab)"
    $dlg.Filter = "Archivos de Imagen|*.png;*.jpg;*.jpeg;*.bmp;*.webp;*.tiff"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    if (Open-Image-Path $dlg.FileName $script:currentTab) {
        $doc = Get-CurrentDoc
        $doc.rects = @()
        $listBox.Items.Clear()
        Update-Canvas
        Save-IniConfig $false
    } else {
        [System.Windows.Forms.MessageBox]::Show("No se pudo abrir la imagen.", "Error")
    }
}

function Update-Canvas {
    $pb = $canvasPictureBox
    $doc = Get-CurrentDoc
    $vp  = $script:viewParams[$script:currentTab]
    
    if (-not $doc.hasImage -or $null -eq $doc.work) {
        $bmp = New-Object System.Drawing.Bitmap ([Math]::Max(1, $pb.Width)), ([Math]::Max(1, $pb.Height))
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::FromArgb(45,45,45))
        $font = New-Object System.Drawing.Font("Segoe UI", 12)
        $g.DrawString("Sin imagen cargada en: $script:currentTab`n`nHaga clic en 'Abrir Imagen' para comenzar.", $font, [System.Drawing.Brushes]::Gray, 20, 20)
        $font.Dispose(); $g.Dispose()
        if ($pb.Image) { $pb.Image.Dispose() }
        $pb.Image = $bmp
        return
    }

    $cw = $pb.ClientSize.Width
    $ch = $pb.ClientSize.Height
    if ($cw -le 0 -or $ch -le 0) { return }

    $iw = $doc.work.Width
    $ih = $doc.work.Height

    $s = [Math]::Min($cw / $iw, $ch / $ih)
    if ($s -gt 1.0) { $s = 1.0 } 
    $vp.scale = $s

    $nw = [int]($iw * $s)
    $nh = [int]($ih * $s)
    $vp.xOffset = [int](($cw - $nw) / 2)
    $vp.yOffset = [int](($ch - $nh) / 2)

    $bmp = New-Object System.Drawing.Bitmap $cw, $ch
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(35,35,35))
    
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($doc.work, $vp.xOffset, $vp.yOffset, $nw, $nh)

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 68, 68), 2.0)
    $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $fontIndex = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $brushText = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Yellow)
    $brushBg   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(180, 0, 0, 0))

    for ($i = 0; $i -lt $doc.rects.Count; $i++) {
        $r = $doc.rects[$i]
        $g.DrawRectangle($pen, $r.X, $r.Y, $r.Width, $r.Height)
        
        $lblStr = "#$i"
        $g.FillRectangle($brushBg, $r.X, $r.Y - 16, 24, 16)
        $g.DrawString($lblStr, $fontIndex, $brushText, $r.X + 2, $r.Y - 15)
    }

    if ($script:isDragging -and $script:dragStart -and $script:dragEnd) {
        $x1 = [Math]::Min($script:dragStart.X, $script:dragEnd.X)
        $y1 = [Math]::Min($script:dragStart.Y, $script:dragEnd.Y)
        $x2 = [Math]::Max($script:dragStart.X, $script:dragEnd.X)
        $y2 = [Math]::Max($script:dragStart.Y, $script:dragEnd.Y)
        $dragPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 200, 50), 2.0)
        $g.DrawRectangle($dragPen, $x1, $y1, ($x2 - $x1), ($y2 - $y1))
        $dragPen.Dispose()
    }

    $pen.Dispose(); $fontIndex.Dispose(); $brushText.Dispose(); $brushBg.Dispose(); $g.Dispose()
    if ($pb.Image) { $pb.Image.Dispose() }
    $pb.Image = $bmp
}

# ── Renderizado de Mosaicos Proporcionales Adaptativos ────────────────────

function Process-SingleBitmap($tabName, $txt, $fontSizeUser, $opacity, $wmColor, $posVal, $fillColor, $toGray) {
    $doc = $script:docs[$tabName]
    if (-not $doc.hasImage) { return $null }
    
    $baseBmp = if ($toGray) { Convert-ToGrayscale $doc.original } else { New-Object System.Drawing.Bitmap $doc.original }
    $g = [System.Drawing.Graphics]::FromImage($baseBmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

    $brush = New-Object System.Drawing.SolidBrush $fillColor
    foreach ($r in $doc.rects) {
        $origRect = Convert-RectToOriginal $r $tabName
        $g.FillRectangle($brush, $origRect)
    }
    $brush.Dispose()

    $calculatedSize = [int]($baseBmp.Width * ($fontSizeUser / 1000.0))
    if ($calculatedSize -lt 8) { $calculatedSize = 8 }

    $fontObj = New-Object System.Drawing.Font ("Arial", $calculatedSize, [System.Drawing.FontStyle]::Bold)
    $alpha   = [int]($opacity * 2.55)
    $wmColorA = [System.Drawing.Color]::FromArgb($alpha, $wmColor.R, $wmColor.G, $wmColor.B)
    $wmBrush  = New-Object System.Drawing.SolidBrush $wmColorA

    $sf = $g.MeasureString($txt, $fontObj)
    $tw = $sf.Width
    $th = $sf.Height
    $iw = $baseBmp.Width
    $ih = $baseBmp.Height
    $margin = [int]($calculatedSize * 0.5)

    if ($posVal -eq "diagonal-tiled") {
        $hSpacing = [int]($tw * 1.5)
        $vSpacing = [int]($th * 3.2)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        
        $oldTransform = $g.Transform
        $g.RotateTransform(-25) 
        
        $rowCounter = 0
        for ($y = -$ih; $y -lt $ih * 2; $y += $vSpacing) {
            $xOffsetRow = if ($rowCounter % 2 -eq 1) { [int]($hSpacing / 2) } else { 0 }
            for ($x = -$iw; $x -lt $iw * 2; $x += $hSpacing) {
                $g.DrawString($txt, $fontObj, $wmBrush, ($x + $xOffsetRow), $y)
            }
            $rowCounter++
        }
        $g.Transform = $oldTransform
    } elseif ($posVal -eq "tiled") {
        $stepY = [int]($th + $calculatedSize * 2)
        $stepX = [int]($tw + $calculatedSize * 2.5)
        for ($y = $margin; $y -lt $ih; $y += $stepY) {
            for ($x = $margin; $x -lt $iw; $x += $stepX) {
                $g.DrawString($txt, $fontObj, $wmBrush, $x, $y)
            }
        }
    } else {
        $placements = @{
            "top-left"      = @($margin, $margin)
            "top-right"     = @(($iw - $tw - $margin), $margin)
            "bottom-left"   = @($margin, ($ih - $th - $margin))
            "bottom-right"  = @(($iw - $tw - $margin), ($ih - $th - $margin))
            "center"        = @((($iw - $tw)/2), (($ih - $th)/2))
        }
        $xy = $placements[$posVal]
        if (-not $xy) { $xy = $placements["bottom-right"] }
        $g.DrawString($txt, $fontObj, $wmBrush, $xy[0], $xy[1])
    }

    $fontObj.Dispose(); $wmBrush.Dispose(); $g.Dispose()
    return $baseBmp
}

function Apply-Effects {
    $hasAny = $false
    foreach ($tab in @("Frontal", "Trasera")) {
        $doc = $script:docs[$tab]
        if ($doc.hasImage) {
            $hasAny = $true
            $processed = Process-SingleBitmap $tab $watermarkText.Text.Trim() $fontSizeTrack.Value $opacityTrack.Value $watermarkColorBtn.BackColor $posCombo.SelectedItem $fillColorBtn.BackColor $grayCheck.Checked
            if ($null -ne $processed) {
                if ($doc.work) { $doc.work.Dispose() }
                $doc.work = $processed
            }
        }
    }
    if (-not $hasAny) {
        [System.Windows.Forms.MessageBox]::Show("Por favor, cargue al menos una imagen antes de aplicar los efectos.", "Aviso")
    } else {
        Update-Canvas
    }
}

# ── Sistema de Exportación Unificado ───────────────────────────────────────

function Save-Image {
    $docFront = $script:docs["Frontal"]
    $docBack  = $script:docs["Trasera"]

    if (-not $docFront.hasImage -and -not $docBack.hasImage) {
        [System.Windows.Forms.MessageBox]::Show("No hay ninguna imagen para exportar.", "Aviso"); return
    }

    $txt = $watermarkText.Text.Trim()
    $fontSize = $fontSizeTrack.Value
    $opacity = $opacityTrack.Value
    $wmColor = $watermarkColorBtn.BackColor
    $posVal = $posCombo.SelectedItem
    $fillColor = $fillColorBtn.BackColor
    $toGray = $grayCheck.Checked

    $outputBmp = $null
    if ($docFront.hasImage -and $docBack.hasImage) {
        $ans = [System.Windows.Forms.MessageBox]::Show("¿Desea combinar ambas caras en un único archivo vertical?`n`n[Sí] = Combinación vertical combinada`n[No] = Guardar únicamente la pestaña visual activa", "Exportar", [System.Windows.Forms.MessageBoxButtons]::YesNoCancel)
        if ($ans -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            $finalFront = Process-SingleBitmap "Frontal" $txt $fontSize $opacity $wmColor $posVal $fillColor $toGray
            $finalBack  = Process-SingleBitmap "Trasera" $txt $fontSize $opacity $wmColor $posVal $fillColor $toGray

            $outW = [Math]::Max($finalFront.Width, $finalBack.Width)
            $outH = $finalFront.Height + $finalBack.Height + 30 

            $outputBmp = New-Object System.Drawing.Bitmap $outW, $outH
            $g = [System.Drawing.Graphics]::FromImage($outputBmp)
            $g.Clear([System.Drawing.Color]::White)
            
            $g.DrawImage($finalFront, [int](($outW - $finalFront.Width)/2), 0)
            $g.DrawImage($finalBack, [int](($outW - $finalBack.Width)/2), ($finalFront.Height + 30))
            
            $g.Dispose(); $finalFront.Dispose(); $finalBack.Dispose()
        }
    }

    if ($null -eq $outputBmp) {
        $outputBmp = Process-SingleBitmap $script:currentTab $txt $fontSize $opacity $wmColor $posVal $fillColor $toGray
    }

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title  = "Guardar Imagen Resultante"
    $dlg.Filter = "PNG Imagen|*.png|JPEG Imagen|*.jpg"
    $dlg.DefaultExt = "png"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ext = [System.IO.Path]::GetExtension($dlg.FileName).ToLower()
        $fmt = if ($ext -eq '.jpg' -or $ext -eq '.jpeg') { [System.Drawing.Imaging.ImageFormat]::Jpeg } else { [System.Drawing.Imaging.ImageFormat]::Png }
        try {
            $outputBmp.Save($dlg.FileName, $fmt)
            [System.Windows.Forms.MessageBox]::Show("¡Documento guardado con éxito!", "Éxito")
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error al escribir el archivo: $_", "Error")
        }
    }
    if ($outputBmp) { $outputBmp.Dispose() }
}

# ── Gestión de Listas de Rectángulos de Limpieza ──────────────────────────

function Sync-Listbox {
    $listBox.Items.Clear()
    $doc = Get-CurrentDoc
    if ($doc.hasImage) {
        for ($i = 0; $i -lt $doc.rects.Count; $i++) {
            [void]$listBox.Items.Add("Zona borrado #$i")
        }
    }
}

function Clear-Selections {
    $doc = Get-CurrentDoc
    $doc.rects = @()
    Sync-Listbox
    Update-Canvas
    Save-IniConfig $false
}

function Remove-Selected {
    if ($listBox.SelectedIndex -lt 0) { return }
    $idx = $listBox.SelectedIndex
    $doc = Get-CurrentDoc
    
    $doc.rects = @($doc.rects[0..($idx-1)] + $doc.rects[($idx+1)..($doc.rects.Count-1)])
    Sync-Listbox
    Update-Canvas
    Save-IniConfig $false
}

# ── Serialización de Archivos de Configuración INI Corregida ────────────────

function Save-IniConfig($verbose) {
    try {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("[General]")
        [void]$sb.AppendLine("Text=$($watermarkText.Text)")
        [void]$sb.AppendLine("FontSize=$($fontSizeTrack.Value)")
        [void]$sb.AppendLine("Opacity=$($opacityTrack.Value)")
        [void]$sb.AppendLine("Position=$($posCombo.SelectedItem)")
        [void]$sb.AppendLine("Grayscale=$($grayCheck.Checked)")
        [void]$sb.AppendLine("FillColor=$($fillColorBtn.BackColor.ToHtml())")
        [void]$sb.AppendLine("WatermarkColor=$($watermarkColorBtn.BackColor.ToHtml())")
        
        foreach ($tab in @("Frontal", "Trasera")) {
            [void]$sb.AppendLine("[$tab]")
            [void]$sb.AppendLine("Path=$($script:docs[$tab].path)")
            $rStrings = @()
            foreach ($r in $script:docs[$tab].rects) {
                $rStrings += "$($r.X),$($r.Y),$($r.Width),$($r.Height)"
            }
            [void]$sb.AppendLine("Rects=$($rStrings -join ';')")
        }
        [System.IO.File]::WriteAllText($script:configFile, $sb.ToString(), [System.Text.Encoding]::UTF8)
        if ($verbose) {
            [System.Windows.Forms.MessageBox]::Show("Configuración guardada correctamente en:`n$script:configFile", "Éxito")
        }
    } catch {
        if ($verbose) {
            [System.Windows.Forms.MessageBox]::Show("Error al guardar configuración: $_", "Error")
        }
    }
}

function Load-IniConfig($verbose) {
    if (-not (Test-Path $script:configFile)) { 
        if ($verbose) { [System.Windows.Forms.MessageBox]::Show("No se encontró ningún archivo de sesión anterior.", "Aviso") }
        return 
    }
    try {
        $lines = Get-Content $script:configFile -Encoding UTF8
        $currentSection = ""
        foreach ($line in $lines) {
            $l = $line.Trim()
            if ($l.StartsWith("[") -and $l.EndsWith("]")) {
                $currentSection = $l.Substring(1, $l.Length - 2)
                continue
            }
            if (-not $l.Contains("=")) { continue }
            $idx = $l.IndexOf("=")
            $key = $l.Substring(0, $idx).Trim()
            $val = $l.Substring($idx + 1).Trim()

            if ($currentSection -eq "General") {
                switch ($key) {
                    "Text"           { $watermarkText.Text = $val }
                    "FontSize"       { $fontSizeTrack.Value = [int]$val; $fsLbl.Text = "Tamaño Letra: $val" }
                    "Opacity"        { $opacityTrack.Value = [int]$val; $opLbl.Text = "Opacidad: $val%" }
                    "Position"       { $posCombo.SelectedItem = $val }
                    "Grayscale"      { $grayCheck.Checked = [System.Convert]::ToBoolean($val) }
                    "FillColor"      { $fillColorBtn.BackColor = [System.Drawing.ColorTranslator]::FromHtml($val) }
                    "WatermarkColor" { $watermarkColorBtn.BackColor = [System.Drawing.ColorTranslator]::FromHtml($val) }
                }
            } elseif ($currentSection -eq "Frontal" -or $currentSection -eq "Trasera") {
                $doc = $script:docs[$currentSection]
                if ($key -eq "Path" -and $val) {
                    [void](Open-Image-Path $val $currentSection)
                } elseif ($key -eq "Rects" -and $val) {
                    $doc.rects = @()
                    $splitRects = $val.Split(';')
                    foreach ($sr in $splitRects) {
                        if (-not $sr) { continue }
                        $coords = $sr.Split(',')
                        if ($coords.Count -eq 4) {
                            $rect = New-Object System.Drawing.Rectangle ([int]$coords[0]), ([int]$coords[1]), ([int]$coords[2]), ([int]$coords[3])
                            $doc.rects += $rect
                        }
                    }
                }
            }
        }
        Sync-Listbox
        Update-Canvas
        if ($verbose) { [System.Windows.Forms.MessageBox]::Show("Sesión restaurada correctamente.", "Éxito") }
    } catch {
        if ($verbose) { [System.Windows.Forms.MessageBox]::Show("Error al cargar sesión: $_", "Error") }
    }
}

# ── UI CONSTRUCCIÓN ────────────────────────────────────────────────────────

$form = New-Object System.Windows.Forms.Form
$form.Text          = "Photo Eraser & Watermark Pro (v7)"
$form.Size          = New-Object System.Drawing.Size(1250, 890)
$form.MinimumSize   = New-Object System.Drawing.Size(950, 700)
$form.StartPosition = "CenterScreen"

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = "Fill"
$mainLayout.ColumnCount = 2
$mainLayout.RowCount = 1

$styleCanvas = New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)
$stylePanel  = New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 290)
[void]$mainLayout.ColumnStyles.Add($styleCanvas)
[void]$mainLayout.ColumnStyles.Add($stylePanel)
$form.Controls.Add($mainLayout)

$leftContainer = New-Object System.Windows.Forms.Panel
$leftContainer.Dock = "Fill"
$mainLayout.Controls.Add($leftContainer, 0, 0)

$tabStrip = New-Object System.Windows.Forms.TabControl
$tabStrip.Dock = "Top"
$tabStrip.Height = 28
[void]$tabStrip.TabPages.Add("Frontal", "Cara Frontal / Delantera")
[void]$tabStrip.TabPages.Add("Trasera", "Cara Trasera / Posterior")
$tabStrip.Add_SelectedIndexChanged({
    $script:currentTab = if ($tabStrip.SelectedIndex -eq 1) { "Trasera" } else { "Frontal" }
    Sync-Listbox
    Update-Canvas
})
$leftContainer.Controls.Add($tabStrip)

$canvasPictureBox = New-Object System.Windows.Forms.PictureBox
$canvasPictureBox.Dock = "Fill"
$canvasPictureBox.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$canvasPictureBox.Cursor = "Cross"
$leftContainer.Controls.Add($canvasPictureBox)
$canvasPictureBox.BringToFront()

$canvasPictureBox.Add_MouseDown({
    if (-not (Get-CurrentDoc).hasImage) { return }
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

    $x1 = [Math]::Min($script:dragStart.X, $script:dragEnd.X)
    $y1 = [Math]::Min($script:dragStart.Y, $script:dragEnd.Y)
    $x2 = [Math]::Max($script:dragStart.X, $script:dragEnd.X)
    $y2 = [Math]::Max($script:dragStart.Y, $script:dragEnd.Y)

    $w = $x2 - $x1
    $h = $y2 - $y1

    if ($w -gt 5 -and $h -gt 5) {
        $rectVisual = New-Object System.Drawing.Rectangle $x1, $y1, $w, $h
        $doc = Get-CurrentDoc
        $doc.rects += $rectVisual
        Sync-Listbox
        Save-IniConfig $false
    }
    Update-Canvas
})
$canvasPictureBox.Add_Resize({ Update-Canvas })

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.AutoScroll = $true
$panel.Padding = New-Object System.Windows.Forms.Padding(10)
$mainLayout.Controls.Add($panel, 1, 0)

$yPos = 10
function Add-GuiElement($obj, $hGap=4) {
    $obj.Location = New-Object System.Drawing.Point(10, $script:yPos)
    if ($obj.Width -eq 0) { $obj.Width = 250 }
    [void]$panel.Controls.Add($obj)
    $script:yPos += $obj.Height + $hGap
}

function Add-GuiLabel($text, $bold=$false) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.AutoSize = $true
    if ($bold) { $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold) }
    Add-GuiElement $lbl 2
}

# --- Construcción de Controles Derechos ---
Add-GuiLabel "Control de Archivos" $true
$openBtn = New-Object System.Windows.Forms.Button -Property @{Text="Abrir Imagen"; Height=28}
$openBtn.Add_Click({ Open-Image })
Add-GuiElement $openBtn

$saveBtn = New-Object System.Windows.Forms.Button -Property @{Text="GUARDAR RESULTADO FINAL"; Height=34; BackColor=[System.Drawing.Color]::LightGreen; Font=New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)}
$saveBtn.Add_Click({ Save-Image })
Add-GuiElement $saveBtn 15

Add-GuiLabel "Regiones de Censura" $true
$listBox = New-Object System.Windows.Forms.ListBox -Property @{Height=85}
Add-GuiElement $listBox

$removeBtn = New-Object System.Windows.Forms.Button -Property @{Text="Eliminar Seleccionada"; Height=25}
$removeBtn.Add_Click({ Remove-Selected })
Add-GuiElement $removeBtn

$clearBtn = New-Object System.Windows.Forms.Button -Property @{Text="Limpiar Todas las Zonas"; Height=25}
$clearBtn.Add_Click({ Clear-Selections })
Add-GuiElement $clearBtn 15

Add-GuiLabel "Color de Ocultación / Tapado" $true
$fillColorBtn = New-Object System.Windows.Forms.Button -Property @{Text="Elegir Color de Relleno"; Height=25; BackColor=[System.Drawing.Color]::DarkGray}
$fillColorBtn.Add_Click({
    $cd = New-Object System.Windows.Forms.ColorDialog
    if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $fillColorBtn.BackColor = $cd.Color; Save-IniConfig $false }
})
Add-GuiElement $fillColorBtn 12

$grayCheck = New-Object System.Windows.Forms.CheckBox -Property @{Text="Convertir imagen a Escala de Grises"; AutoSize=$true; Checked=$false}
$grayCheck.Add_CheckedChanged({ Save-IniConfig $false })
Add-GuiElement $grayCheck 15

Add-GuiLabel "Configuración Marca de Agua" $true

Add-GuiLabel "Texto de Protección:"
$watermarkText = New-Object System.Windows.Forms.TextBox -Property @{Text="COPIA RESTRINGIDA"}
$watermarkText.Add_TextChanged({ Save-IniConfig $false })
Add-GuiElement $watermarkText

$fsLbl = New-Object System.Windows.Forms.Label -Property @{Text="Tamaño Letra: 35"; AutoSize=$true}
Add-GuiElement $fsLbl 0
$fontSizeTrack = New-Object System.Windows.Forms.TrackBar -Property @{Minimum=10; Maximum=150; Value=35; Height=30; TickFrequency=10}
$fontSizeTrack.Add_Scroll({ $fsLbl.Text = "Tamaño Letra: $($fontSizeTrack.Value)"; Save-IniConfig $false })
Add-GuiElement $fontSizeTrack

$opLbl = New-Object System.Windows.Forms.Label -Property @{Text="Opacidad: 35%"; AutoSize=$true}
Add-GuiElement $opLbl 0
$opacityTrack = New-Object System.Windows.Forms.TrackBar -Property @{Minimum=5; Maximum=100; Value=35; Height=30; TickFrequency=10}
$opacityTrack.Add_Scroll({ $opLbl.Text = "Opacidad: $($opacityTrack.Value)%"; Save-IniConfig $false })
Add-GuiElement $opacityTrack

Add-GuiLabel "Posición y Estilo:"
$posCombo = New-Object System.Windows.Forms.ComboBox -Property @{DropDownStyle="DropDownList"}
[void]$posCombo.Items.AddRange(@("top-left", "top-right", "bottom-left", "bottom-right", "center", "tiled", "diagonal-tiled"))
$posCombo.SelectedIndex = 6
$posCombo.Add_SelectedIndexChanged({ Save-IniConfig $false })
Add-GuiElement $posCombo

Add-GuiLabel "Color Texto:"
$watermarkColorBtn = New-Object System.Windows.Forms.Button -Property @{Text="Elegir Color"; Height=25; BackColor=[System.Drawing.Color]::Red}
$watermarkColorBtn.Add_Click({
    $cd = New-Object System.Windows.Forms.ColorDialog
    if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $watermarkColorBtn.BackColor = $cd.Color; Save-IniConfig $false }
})
Add-GuiElement $watermarkColorBtn 12

$applyBtn = New-Object System.Windows.Forms.Button -Property @{Text="APLICAR EFECTOS"; Height=42; Font=New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold); BackColor=[System.Drawing.Color]::LightSkyBlue}
$applyBtn.Add_Click({ Apply-Effects })
Add-GuiElement $applyBtn 20

Add-GuiLabel "Persistencia de Datos" $true
$btnSaveSession = New-Object System.Windows.Forms.Button -Property @{Text="Guardar Configuración"; Height=26; BackColor=[System.Drawing.Color]::WhiteSmoke}
$btnSaveSession.Add_Click({ Save-IniConfig $true })
Add-GuiElement $btnSaveSession

$btnLoadSession = New-Object System.Windows.Forms.Button -Property @{Text="Cargar Configuración"; Height=26; BackColor=[System.Drawing.Color]::WhiteSmoke}
$btnLoadSession.Add_Click({ Load-IniConfig $true })
Add-GuiElement $btnLoadSession

# Eventos de Ciclo de Vida corregidos
$form.Add_FormClosing({ Save-IniConfig $false })
$form.Add_Load({ Load-IniConfig $false })

$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq 'O') { Open-Image; $_.SuppressKeyPress = $true }
    if ($_.Control -and $_.KeyCode -eq 'S') { Save-Image; $_.SuppressKeyPress = $true }
})
$form.KeyPreview = $true

[void]$form.ShowDialog()