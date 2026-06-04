<# 
 .SYNOPSIS
  DNI Eraser & Watermark Pro - Privacy Edition 2026 (v17 - Corrección de Recientes y Ajuste de Interfaz)
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Localización del Archivo de Configuración ──────────────────────
$script:scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
if (-not $script:scriptPath -or -not (Test-Path $script:scriptPath -PathType Container)) { 
    $script:scriptPath = [System.IO.Directory]::GetCurrentDirectory() 
}
$script:configFile = Join-Path $script:scriptPath "session_config.ini"

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

# ── Estado Global ──────────────────────────────────────────────────
$script:docs = @{
    "Frontal" = @{ original = $null; work = $null; rects = @(); hasImage = $false; path = $null }
    "Trasera" = @{ original = $null; work = $null; rects = @(); hasImage = $false; path = $null }
}
$script:currentTab   = "Frontal"
$script:isDragging   = $false
$script:dragStart    = $null
$script:dragEnd      = $null
$script:loading      = $false

# ID de la sesión actual (por defecto ImageCombo0 si está vacío)
$script:currentComboId = "ImageCombo0"

$script:viewParams = @{
    "Frontal" = @{ scale = 1.0; xOffset = 0; yOffset = 0 }
    "Trasera" = @{ scale = 1.0; xOffset = 0; yOffset = 0 }
}

# ── UI CONSTRUCCIÓN ────────────────────────────────────────────────

$form = New-Object System.Windows.Forms.Form
$form.Text          = "DNI Eraser & Watermark Pro (v17)"
$form.Size          = New-Object System.Drawing.Size(1250, 930) # Reducido 50px de altura (de 980 a 930)
$form.MinimumSize   = New-Object System.Drawing.Size(950, 700)
$form.StartPosition = "CenterScreen"

# --- Barra de Menú Superior ---
$menuBar = New-Object System.Windows.Forms.MenuStrip

# Menú Configuraciones
$menuConfig = New-Object System.Windows.Forms.ToolStripMenuItem("Configuraciones")
$menuSaveSession = New-Object System.Windows.Forms.ToolStripMenuItem("Guardar configuración")
$menuLoadSession = New-Object System.Windows.Forms.ToolStripMenuItem("Cargar configuración")
$menuRecents = New-Object System.Windows.Forms.ToolStripMenuItem("Recientes")

[void]$menuConfig.DropDownItems.Add($menuSaveSession)
[void]$menuConfig.DropDownItems.Add($menuLoadSession)
[void]$menuConfig.DropDownItems.Add($menuRecents)

# Menú Ayuda
$menuHelp = New-Object System.Windows.Forms.ToolStripMenuItem("Ayuda")
$menuAbout = New-Object System.Windows.Forms.ToolStripMenuItem("Acerca de")
[void]$menuHelp.DropDownItems.Add($menuAbout)

[void]$menuBar.Items.Add($menuConfig)
[void]$menuBar.Items.Add($menuHelp)
$form.MainMenuStrip = $menuBar
$form.Controls.Add($menuBar)

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = "Fill"
$mainLayout.ColumnCount = 2
$mainLayout.RowCount = 1

$styleCanvas = New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)
$stylePanel  = New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 290)
[void]$mainLayout.ColumnStyles.Add($styleCanvas)
[void]$mainLayout.ColumnStyles.Add($stylePanel)
$form.Controls.Add($mainLayout)
$mainLayout.BringToFront()

$leftContainer = New-Object System.Windows.Forms.Panel
$leftContainer.Dock = "Fill"
$mainLayout.Controls.Add($leftContainer, 0, 0)

$tabStrip = New-Object System.Windows.Forms.TabControl
$tabStrip.Dock = "Top"
$tabStrip.Height = 28
[void]$tabStrip.TabPages.Add("Frontal", "Cara frontal / delantera")
[void]$tabStrip.TabPages.Add("Trasera", "Cara trasera / posterior")
$leftContainer.Controls.Add($tabStrip)

$canvasPictureBox = New-Object System.Windows.Forms.PictureBox
$canvasPictureBox.Dock = "Fill"
$canvasPictureBox.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$canvasPictureBox.Cursor = "Cross"
$leftContainer.Controls.Add($canvasPictureBox)
$canvasPictureBox.BringToFront()

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.AutoScroll = $true
$panel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 24, 12)
$mainLayout.Controls.Add($panel, 1, 0)

$yPos = 12
function Add-GuiElement($obj, $hGap=6) {
    $obj.Location = New-Object System.Drawing.Point(12, $script:yPos)
    $obj.Width = $panel.ClientSize.Width - 24
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

# --- Elementos del panel lateral ---
Add-GuiLabel "Control de archivos" $true
$openBtn = New-Object System.Windows.Forms.Button -Property @{Text="Cargar imagen"; Height=28}
Add-GuiElement $openBtn

$saveBtn = New-Object System.Windows.Forms.Button -Property @{Text="GUARDAR RESULTADO FINAL"; Height=36; BackColor=[System.Drawing.Color]::LightGreen; Font=New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)}
Add-GuiElement $saveBtn 12

Add-GuiLabel "Zonas de censura" $true
$listBox = New-Object System.Windows.Forms.ListBox -Property @{Height=80}
Add-GuiElement $listBox

$removeBtn = New-Object System.Windows.Forms.Button -Property @{Text="Eliminar zonas seleccionadas"; Height=24}
Add-GuiElement $removeBtn

$clearBtn = New-Object System.Windows.Forms.Button -Property @{Text="Limpiar todas las zonas"; Height=24}
Add-GuiElement $clearBtn 12

$fillColorBtn = New-Object System.Windows.Forms.Button -Property @{Text="Elegir color de relleno"; Height=24; BackColor=[System.Drawing.Color]::DarkGray}
Add-GuiElement $fillColorBtn 15

Add-GuiLabel "Configuración de la marca de agua" $true

Add-GuiLabel "Línea 1: entidad / destinatario"
$txtLine1 = New-Object System.Windows.Forms.TextBox -Property @{Text=""}
Add-GuiElement $txtLine1 4

Add-GuiLabel "Línea 2: motivo / uso exclusivo"
$txtLine2 = New-Object System.Windows.Forms.TextBox -Property @{Text=""}
Add-GuiElement $txtLine2

$fsLbl = New-Object System.Windows.Forms.Label -Property @{Text="Tamaño letra: 35"; AutoSize=$true}
Add-GuiElement $fsLbl 0
$fontSizeTrack = New-Object System.Windows.Forms.TrackBar -Property @{Minimum=10; Maximum=150; Value=35; Height=30; TickFrequency=10}
Add-GuiElement $fontSizeTrack

$opLbl = New-Object System.Windows.Forms.Label -Property @{Text="Opacidad: 35%"; AutoSize=$true}
Add-GuiElement $opLbl 0
$opacityTrack = New-Object System.Windows.Forms.TrackBar -Property @{Minimum=5; Maximum=100; Value=35; Height=30; TickFrequency=10}
Add-GuiElement $opacityTrack

Add-GuiLabel "Posición y estilo:"
$posCombo = New-Object System.Windows.Forms.ComboBox -Property @{DropDownStyle="DropDownList"}
[void]$posCombo.Items.AddRange(@("top-left", "top-right", "bottom-left", "bottom-right", "center", "tiled", "diagonal-tiled"))
$posCombo.SelectedIndex = 6
Add-GuiElement $posCombo 10

$watermarkColorBtn = New-Object System.Windows.Forms.Button -Property @{Text="Elegir color de la marca de agua"; Height=24; BackColor=[System.Drawing.Color]::Red}
Add-GuiElement $watermarkColorBtn 15

Add-GuiLabel "Otras opciones" $true
$grayCheck = New-Object System.Windows.Forms.CheckBox -Property @{Text="Convertir imagen a escala de grises"; AutoSize=$true; Checked=$false}
Add-GuiElement $grayCheck 15

$applyBtn = New-Object System.Windows.Forms.Button -Property @{Text="APLICAR EFECTOS"; Height=42; Font=New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold); BackColor=[System.Drawing.Color]::LightSkyBlue}
Add-GuiElement $applyBtn 15

# Botón LIMPIAR EDITOR
$btnClearEditor = New-Object System.Windows.Forms.Button -Property @{Text="LIMPIAR EDITOR"; Height=32; BackColor=[System.Drawing.Color]::Khaki; Font=New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)}
Add-GuiElement $btnClearEditor


# ── LOGICA Y FUNCIONES ─────────────────────────────────────────────────────

function Get-CurrentDoc { return $script:docs[$script:currentTab] }

function Get-RelativeOrAbsolute($fullPath) {
    if (-not $fullPath) { return "" }
    $resolvedPath = Resolve-Path $fullPath -ErrorAction SilentlyContinue
    if ($resolvedPath) { $fullPath = $resolvedPath.Path }
    if ($fullPath.StartsWith($script:scriptPath)) {
        $relative = $fullPath.Substring($script:scriptPath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
        return ".\$relative"
    }
    return $fullPath
}

function Resolve-PathSmart($rawPath) {
    if (-not $rawPath) { return "" }
    if ($rawPath.StartsWith(".\") -or $rawPath.StartsWith("./")) {
        $clean = $rawPath.Substring(2)
        return [System.IO.Path]::GetFullPath((Join-Path $script:scriptPath $clean))
    }
    return [System.IO.Path]::GetFullPath($rawPath)
}

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

function Open-Image-Path($path, $tabName) {
    $fullPath = Resolve-PathSmart $path
    if (-not (Test-Path $fullPath)) { return $false }
    try {
        $stream = New-Object System.IO.FileStream($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        $img = [System.Drawing.Image]::FromStream($stream)
        $stream.Close(); $stream.Dispose()
        $doc = $script:docs[$tabName]
        if ($doc.original) { $doc.original.Dispose() }
        if ($doc.work) { $doc.work.Dispose() }
        $doc.original = New-Object System.Drawing.Bitmap $img
        $doc.work     = New-Object System.Drawing.Bitmap $doc.original
        $img.Dispose()
        $doc.hasImage = $true
        $doc.path     = $fullPath
        return $true
    } catch {
        return $false
    }
}

function Open-Image {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = "Seleccionar imagen ($script:currentTab)"
    $dlg.Filter = "Archivos de imagen|*.png;*.jpg;*.jpeg;*.bmp;*.webp;*.tiff"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    
    if ($script:currentComboId -eq "ImageCombo0" -and -not $script:docs["Frontal"].hasImage -and -not $script:docs["Trasera"].hasImage) {
        $script:currentComboId = Get-NextFreeComboId
    }

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
        $g.DrawString("Sin imagen cargada en: $script:currentTab`n`nHaga clic en 'Cargar imagen' para comenzar.", $font, [System.Drawing.Brushes]::Gray, 20, 20)
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

function Process-SingleBitmap($tabName, $line1, $line2, $fontSizeUser, $opacity, $wmColor, $posVal, $fillColor, $toGray) {
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
    
    if (-not $line1 -and -not $line2) { $g.Dispose(); return $baseBmp }

    $sizeL1 = [int]($baseBmp.Width * ($fontSizeUser / 1000.0))
    if ($sizeL1 -lt 8) { $sizeL1 = 8 }
    $sizeL2 = [int]($sizeL1 * 0.65)
    if ($sizeL2 -lt 6) { $sizeL2 = 6 }
    $fontL1 = New-Object System.Drawing.Font ("Arial", $sizeL1, [System.Drawing.FontStyle]::Bold)
    $fontL2 = New-Object System.Drawing.Font ("Arial", $sizeL2, [System.Drawing.FontStyle]::Bold)
    $alpha   = [int]($opacity * 2.55)
    $wmColorA = [System.Drawing.Color]::FromArgb($alpha, $wmColor.R, $wmColor.G, $wmColor.B)
    $wmBrush  = New-Object System.Drawing.SolidBrush $wmColorA
    
    $sf1 = if ($line1) { $g.MeasureString($line1, $fontL1) } else { [System.Drawing.SizeF]::new(0,0) }
    $sf2 = if ($line2) { $g.MeasureString($line2, $fontL2) } else { [System.Drawing.SizeF]::new(0,0) }
    $totalW = [Math]::Max($sf1.Width, $sf2.Width)
    
    $lineGap = [int]($sizeL1 * 0.12)
    $totalH = if ($line1 -and $line2) { ($sf1.Height * 0.95) + ($sf2.Height * 0.95) + $lineGap } elseif ($line1) { $sf1.Height } else { $sf2.Height }
    
    $iw = $baseBmp.Width
    $ih = $baseBmp.Height
    $margin = [int]($sizeL1 * 0.5)

    $DrawWatermarkBlock = {
        param($gCtx, $bx, $by)
        $currentY = $by
        if ($line1) {
            $x1 = $bx + (($totalW - $sf1.Width) / 2)
            $gCtx.DrawString($line1, $fontL1, $wmBrush, $x1, $currentY)
            $currentY += ($sf1.Height * 0.90) + $lineGap
        }
        if ($line2) {
            $x2 = $bx + (($totalW - $sf2.Width) / 2)
            $gCtx.DrawString($line2, $fontL2, $wmBrush, $x2, $currentY)
        }
    }

    if ($posVal -eq "diagonal-tiled") {
        $hSpacing = [int]($totalW * 1.4)
        $vSpacing = [int]($totalH * 1.6) 
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $oldTransform = $g.Transform
        $g.RotateTransform(-25) 
        $rowCounter = 0
        for ($y = -$ih * 2; $y -lt $ih * 3; $y += $vSpacing) {
            $xOffsetRow = if ($rowCounter % 2 -eq 1) { [int]($hSpacing / 2) } else { 0 }
            for ($x = -$iw * 2; $x -lt $iw * 3; $x += $hSpacing) {
                & $DrawWatermarkBlock $g ($x + $xOffsetRow) $y
            }
            $rowCounter++
        }
        $g.Transform = $oldTransform
    } elseif ($posVal -eq "tiled") {
        $stepY = [int]($totalH * 1.1)
        $stepX = [int]($totalW + $sizeL1 * 3.5)
        for ($y = $margin; $y -lt ($ih - $totalH + $stepY); $y += $stepY) {
            for ($x = $margin; $x -lt ($iw - $totalW); $x += $stepX) {
                & $DrawWatermarkBlock $g $x $y
            }
        }
    } else {
        $placements = @{
            "top-left"      = @($margin, $margin)
            "top-right"     = @(($iw - $totalW - $margin), $margin)
            "bottom-left"   = @($margin, ($ih - $totalH - $margin))
            "bottom-right"  = @(($iw - $totalW - $margin), ($ih - $totalH - $margin))
            "center"        = @((($iw - $totalW)/2), (($ih - $totalH)/2))
        }
        $xy = $placements[$posVal]
        if (-not $xy) { $xy = $placements["bottom-right"] }
        & $DrawWatermarkBlock $g $xy[0] $xy[1]
    }
    $fontL1.Dispose(); $fontL2.Dispose(); $wmBrush.Dispose(); $g.Dispose()
    return $baseBmp
}

function Apply-Effects {
    $hasAny = $false
    foreach ($tab in @("Frontal", "Trasera")) {
        $doc = $script:docs[$tab]
        if ($doc.hasImage) {
            $hasAny = $true
            $processed = Process-SingleBitmap $tab $txtLine1.Text.Trim() $txtLine2.Text.Trim() $fontSizeTrack.Value $opacityTrack.Value $watermarkColorBtn.BackColor $posCombo.SelectedItem $fillColorBtn.BackColor $grayCheck.Checked
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

function Save-Image {
    $docFront = $script:docs["Frontal"]
    $docBack  = $script:docs["Trasera"]
    if (-not $docFront.hasImage -and -not $docBack.hasImage) {
        [System.Windows.Forms.MessageBox]::Show("No hay ninguna imagen para guardar.", "Aviso"); return
    }
    $l1 = $txtLine1.Text.Trim(); $l2 = $txtLine2.Text.Trim()
    $fontSize = $fontSizeTrack.Value; $opacity = $opacityTrack.Value
    $wmColor = $watermarkColorBtn.BackColor; $posVal = $posCombo.SelectedItem
    $fillColor = $fillColorBtn.BackColor; $toGray = $grayCheck.Checked

    $outputBmp = $null
    if ($docFront.hasImage -and $docBack.hasImage) {
        $lang = [System.Threading.Thread]::CurrentThread.CurrentUICulture.TwoLetterISOLanguageName
        $yesLabel = if ($lang -eq "es") { "[Sí]" } else { "[Yes]" }
        $noLabel  = if ($lang -eq "es") { "[No]" } else { "[No]" }
        $msgText = "¿Desea combinar ambas caras en una única imagen vertical?`n`n$yesLabel = Combinación vertical combinada`n$noLabel = Guardar únicamente la pestaña visual activa"
        $ans = [System.Windows.Forms.MessageBox]::Show($msgText, "Guardar", [System.Windows.Forms.MessageBoxButtons]::YesNoCancel)
        if ($ans -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            $finalFront = Process-SingleBitmap "Frontal" $l1 $l2 $fontSize $opacity $wmColor $posVal $fillColor $toGray
            $finalBack  = Process-SingleBitmap "Trasera" $l1 $l2 $fontSize $opacity $wmColor $posVal $fillColor $toGray
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
        $outputBmp = Process-SingleBitmap $script:currentTab $l1 $l2 $fontSize $opacity $wmColor $posVal $fillColor $toGray
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title  = "Guardar imagen resultante"
    $dlg.Filter = "PNG Imagen|*.png|JPEG Imagen|*.jpg"
    $dlg.DefaultExt = "png"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ext = [System.IO.Path]::GetExtension($dlg.FileName).ToLower()
        $fmt = if ($ext -eq '.jpg' -or $ext -eq '.jpeg') { [System.Drawing.Imaging.ImageFormat]::Jpeg } else { [System.Drawing.Imaging.ImageFormat]::Png }
        try {
            $outputBmp.Save($dlg.FileName, $fmt)
            [System.Windows.Forms.MessageBox]::Show("Imagen guardada con éxito", "Éxito")
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error al escribir el archivo: $_", "Error")
        }
    }
    if ($outputBmp) { $outputBmp.Dispose() }
}

function Sync-Listbox {
    $listBox.Items.Clear()
    $doc = Get-CurrentDoc
    if ($doc.hasImage) {
        for ($i = 0; $i -lt $doc.rects.Count; $i++) {
            [void]$listBox.Items.Add("Zona censurada #$i")
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

function Reset-Editor {
    $script:loading = $true
    
    foreach ($tab in @("Frontal", "Trasera")) {
        $doc = $script:docs[$tab]
        if ($doc.original) { $doc.original.Dispose(); $doc.original = $null }
        if ($doc.work) { $doc.work.Dispose(); $doc.work = $null }
        $doc.rects = @()
        $doc.hasImage = $false
        $doc.path = $null
    }

    $txtLine1.Text = ""
    $txtLine2.Text = ""
    $fontSizeTrack.Value = 35
    $fsLbl.Text = "Tamaño letra: 35"
    $opacityTrack.Value = 35
    $opLbl.Text = "Opacidad: 35%"
    $posCombo.SelectedIndex = 6
    $grayCheck.Checked = $false
    $fillColorBtn.BackColor = [System.Drawing.Color]::DarkGray
    $watermarkColorBtn.BackColor = [System.Drawing.Color]::Red

    $script:currentComboId = "ImageCombo0"

    $script:loading = $false
    Sync-Listbox
    Update-Canvas
}

function Get-NextFreeComboId {
    if (-not (Test-Path $script:configFile)) { return "ImageCombo0" }
    $ini = Get-ParsedIni
    $i = 0
    while ($ini.ContainsKey("ImageCombo$i")) { $i++ }
    return "ImageCombo$i"
}

function Get-ParsedIni {
    $dict = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.Dictionary[string, string]]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path $script:configFile)) { return $dict }
    $lines = Get-Content $script:configFile -Encoding UTF8
    $currentSec = ""
    foreach ($line in $lines) {
        $l = $line.Trim()
        if ($l.StartsWith("[") -and $l.EndsWith("]")) {
            $currentSec = $l.Substring(1, $l.Length - 2)
            if (-not $dict.ContainsKey($currentSec)) {
                $dict[$currentSec] = New-Object 'System.Collections.Generic.Dictionary[string, string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
            }
            continue
        }
        if (-not $l.Contains("=") -or !$currentSec) { continue }
        $idx = $l.IndexOf("=")
        $key = $l.Substring(0, $idx).Trim()
        $val = $l.Substring($idx + 1).Trim()
        $dict[$currentSec][$key] = $val
    }
    return $dict
}

# --- MENU RECIENTES CORREGIDO (v17) ---
function Update-RecentsMenu {
    $menuRecents.DropDownItems.Clear()
    $ini = Get-ParsedIni
    $hasRecents = $false

    foreach ($sec in $ini.Keys) {
        if ($sec.StartsWith("ImageCombo", [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($ini[$sec].ContainsKey("Name")) {
                $name = $ini[$sec]["Name"]
                $item = New-Object System.Windows.Forms.ToolStripMenuItem($name)
                
                # Guardamos el ID del combo directamente en el Tag del elemento de menú
                $item.Tag = $sec 
                
                # Vinculamos la acción usando el remitente ($this) para evitar fallos de ámbito
                $item.Add_Click({
                    Load-SpecificComboId $this.Tag
                })
                
                [void]$menuRecents.DropDownItems.Add($item)
                $hasRecents = $true
            }
        }
    }
    if (-not $hasRecents) {
        $emptyItem = New-Object System.Windows.Forms.ToolStripMenuItem("(No hay documentos recientes)")
        $emptyItem.Enabled = $false
        [void]$menuRecents.DropDownItems.Add($emptyItem)
    }
}

function Load-SpecificComboId($comboId) {
    try {
        $script:loading = $true
        $ini = Get-ParsedIni
        if (-not $ini.ContainsKey($comboId)) { return }
        
        foreach ($tab in @("Frontal", "Trasera")) {
            $doc = $script:docs[$tab]
            if ($doc.original) { $doc.original.Dispose(); $doc.original = $null }
            if ($doc.work) { $doc.work.Dispose(); $doc.work = $null }
            $doc.rects = @()
            $doc.hasImage = $false
            $doc.path = $null
        }

        $sec = $ini[$comboId]
        $script:currentComboId = $comboId

        if ($sec.ContainsKey("Line1")) { $txtLine1.Text = $sec["Line1"] }
        if ($sec.ContainsKey("Line2")) { $txtLine2.Text = $sec["Line2"] }
        if ($sec.ContainsKey("FontSize")) { $fontSizeTrack.Value = [int]$sec["FontSize"]; $fsLbl.Text = "Tamaño letra: $($sec["FontSize"])" }
        if ($sec.ContainsKey("Opacity")) { $opacityTrack.Value = [int]$sec["Opacity"]; $opLbl.Text = "Opacidad: $($sec["Opacity"])%" }
        if ($sec.ContainsKey("Position")) { $posCombo.SelectedItem = $sec["Position"] }
        if ($sec.ContainsKey("Grayscale")) { $grayCheck.Checked = [System.Convert]::ToBoolean($sec["Grayscale"]) }
        if ($sec.ContainsKey("FillColor")) { $fillColorBtn.BackColor = [System.Drawing.ColorTranslator]::FromHtml($sec["FillColor"]) }
        if ($sec.ContainsKey("WatermarkColor")) { $watermarkColorBtn.BackColor = [System.Drawing.ColorTranslator]::FromHtml($sec["WatermarkColor"]) }

        if ($sec.ContainsKey("FrontalPath") -and $sec["FrontalPath"]) {
            [void](Open-Image-Path $sec["FrontalPath"] "Frontal")
        }
        if ($sec.ContainsKey("FrontalRects") -and $sec["FrontalRects"]) {
            $script:docs["Frontal"].rects = @()
            foreach ($sr in $sec["FrontalRects"].Split(';')) {
                if (-not $sr) { continue }
                $coords = $sr.Split(',')
                if ($coords.Count -eq 4) {
                    $script:docs["Frontal"].rects += New-Object System.Drawing.Rectangle ([int]$coords[0]), ([int]$coords[1]), ([int]$coords[2]), ([int]$coords[3])
                }
            }
        }

        if ($sec.ContainsKey("RearPath") -and $sec["RearPath"]) {
            [void](Open-Image-Path $sec["RearPath"] "Trasera")
        }
        if ($sec.ContainsKey("RearRects") -and $sec["RearRects"]) {
            $script:docs["Trasera"].rects = @()
            foreach ($sr in $sec["RearRects"].Split(';')) {
                if (-not $sr) { continue }
                $coords = $sr.Split(',')
                if ($coords.Count -eq 4) {
                    $script:docs["Trasera"].rects += New-Object System.Drawing.Rectangle ([int]$coords[0]), ([int]$coords[1]), ([int]$coords[2]), ([int]$coords[3])
                }
            }
        }

        Sync-Listbox
        Update-Canvas
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error al cargar la sesión específica: $_", "Error")
    } finally {
        $script:loading = $false
    }
}

function Save-IniConfig($verbose) {
    if ($script:loading -and -not $verbose) { return }
    try {
        $ini = Get-ParsedIni

        if (-not $ini.ContainsKey("General")) {
            $ini["General"] = New-Object 'System.Collections.Generic.Dictionary[string, string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        }
        $ini["General"]["LastImageCombo"] = $script:currentComboId

        $nameFront = if ($script:docs["Frontal"].path) { [System.IO.Path]::GetFileNameWithoutExtension($script:docs["Frontal"].path) } else { "" }
        $nameBack  = if ($script:docs["Trasera"].path) { [System.IO.Path]::GetFileNameWithoutExtension($script:docs["Trasera"].path) } else { "" }
        
        # Modificado: Uso del separador "|" en lugar de "x"
        $combinedName = ""
        if ($nameFront -and $nameBack) { $combinedName = "$nameFront | $nameBack" }
        elseif ($nameFront) { $combinedName = $nameFront }
        elseif ($nameBack) { $combinedName = $nameBack }
        else { $combinedName = "Sesión vacía sin imágenes" }

        if (-not $ini.ContainsKey($script:currentComboId)) {
            $ini[$script:currentComboId] = New-Object 'System.Collections.Generic.Dictionary[string, string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        }

        $sec = $ini[$script:currentComboId]
        $sec["Name"]           = $combinedName
        $sec["Line1"]          = $txtLine1.Text
        $sec["Line2"]          = $txtLine2.Text
        $sec["FontSize"]       = $fontSizeTrack.Value.ToString()
        $sec["Opacity"]        = $opacityTrack.Value.ToString()
        $sec["Position"]       = $posCombo.SelectedItem
        $sec["Grayscale"]      = $grayCheck.Checked.ToString()
        $sec["FillColor"]      = [System.Drawing.ColorTranslator]::ToHtml($fillColorBtn.BackColor)
        $sec["WatermarkColor"] = [System.Drawing.ColorTranslator]::ToHtml($watermarkColorBtn.BackColor)
        $sec["FrontalPath"]    = Get-RelativeOrAbsolute $script:docs["Frontal"].path
        $sec["RearPath"]       = Get-RelativeOrAbsolute $script:docs["Trasera"].path

        $fRects = @()
        foreach ($r in $script:docs["Frontal"].rects) { $fRects += "$($r.X),$($r.Y),$($r.Width),$($r.Height)" }
        $sec["FrontalRects"]   = $fRects -join ';'

        $rRects = @()
        foreach ($r in $script:docs["Trasera"].rects) { $rRects += "$($r.X),$($r.Y),$($r.Width),$($r.Height)" }
        $sec["RearRects"]      = $rRects -join ';'

        $sb = New-Object System.Text.StringBuilder
        foreach ($sectionName in $ini.Keys) {
            [void]$sb.AppendLine("[$sectionName]")
            foreach ($key in $ini[$sectionName].Keys) {
                [void]$sb.AppendLine("$key=$($ini[$sectionName][$key])")
            }
        }

        [System.IO.File]::WriteAllText($script:configFile, $sb.ToString(), [System.Text.Encoding]::UTF8)
        Update-RecentsMenu

        if ($verbose) {
            [System.Windows.Forms.MessageBox]::Show("Configuración guardada correctamente en el perfil actual.", "Éxito")
        }
    } catch {
        if ($verbose) { [System.Windows.Forms.MessageBox]::Show("Error al guardar configuración: $_", "Error") }
    }
}

function Load-IniConfig($verbose) {
    if (-not (Test-Path $script:configFile)) { 
        if ($verbose) { [System.Windows.Forms.MessageBox]::Show("No se encontró ningún archivo de sesión anterior.", "Aviso") }
        Update-RecentsMenu
        return 
    }
    try {
        $ini = Get-ParsedIni
        $targetCombo = "ImageCombo0"
        if ($ini.ContainsKey("General") -and $ini["General"].ContainsKey("LastImageCombo")) {
            $targetCombo = $ini["General"]["LastImageCombo"]
        }
        if ($ini.ContainsKey($targetCombo)) {
            Load-SpecificComboId $targetCombo
        }
        Update-RecentsMenu
        if ($verbose) { [System.Windows.Forms.MessageBox]::Show("Última configuración activa restaurada.", "Éxito") }
    } catch {
        if ($verbose) { [System.Windows.Forms.MessageBox]::Show("Error al cargar configuración general: $_", "Error") }
    }
}


# ── ASIGNACIÓN DE EVENTOS ──────────────────────────────────────────────────

$menuAbout.Add_Click({
    $aboutText = "DNI Eraser & Watermark Pro`nVersión 17.0 (Edición Privacidad 2026)`n`nDiseñado para la edición local segura de documentos de identidad de forma 100% privada.`n`nDesarrollado para Manel.`nSin telemetría ni conexiones externas."
    [System.Windows.Forms.MessageBox]::Show($aboutText, "Acerca de este programa", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
})

$menuSaveSession.Add_Click({ Save-IniConfig $true })
$menuLoadSession.Add_Click({ Load-IniConfig $true })

$tabStrip.Add_SelectedIndexChanged({
    $script:currentTab = if ($tabStrip.SelectedIndex -eq 1) { "Trasera" } else { "Frontal" }
    Sync-Listbox
    Update-Canvas
})

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

$openBtn.Add_Click({ Open-Image })
$saveBtn.Add_Click({ Save-Image })
$removeBtn.Add_Click({ Remove-Selected })
$clearBtn.Add_Click({ Clear-Selections })
$applyBtn.Add_Click({ Apply-Effects })
$btnClearEditor.Add_Click({ Reset-Editor })

$fillColorBtn.Add_Click({
    $cd = New-Object System.Windows.Forms.ColorDialog
    if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $fillColorBtn.BackColor = $CD.Color; Save-IniConfig $false }
})

$watermarkColorBtn.Add_Click({
    $cd = New-Object System.Windows.Forms.ColorDialog
    if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $watermarkColorBtn.BackColor = $CD.Color; Save-IniConfig $false }
})

$txtLine1.Add_TextChanged({ Save-IniConfig $false })
$txtLine2.Add_TextChanged({ Save-IniConfig $false })
$fontSizeTrack.Add_Scroll({ $fsLbl.Text = "Tamaño letra: $($fontSizeTrack.Value)"; Save-IniConfig $false })
$opacityTrack.Add_Scroll({ $opLbl.Text = "Opacidad: $($opacityTrack.Value)%"; Save-IniConfig $false })
$posCombo.Add_SelectedIndexChanged({ Save-IniConfig $false })
$grayCheck.Add_CheckedChanged({ Save-IniConfig $false })

$form.Add_FormClosing({ Save-IniConfig $false })
$form.Add_Load({ Load-IniConfig $false })

$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq 'O') { Open-Image; $_.SuppressKeyPress = $true }
    if ($_.Control -and $_.KeyCode -eq 'S') { Save-Image; $_.SuppressKeyPress = $true }
})
$form.KeyPreview = $true

[void]$form.ShowDialog()