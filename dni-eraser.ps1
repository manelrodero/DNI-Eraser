<# 
 .SYNOPSIS
  Photo Eraser & Watermark Tool (Versión Mejorada Doble Cara)
 .DESCRIPTION
  Permite cargar la cara frontal y trasera de un documento, censurar zonas
  y aplicar marcas de agua localmente protegiendo la privacidad.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Estado Global Extendido ────────────────────────────────────────────────
$script:docs = @{
    "Frontal" = @{ original = $null; work = $null; rects = @(); hasImage = $false; path = $null }
    "Trasera" = @{ original = $null; work = $null; rects = @(); hasImage = $false; path = $null }
}
$script:currentTab   = "Frontal"
$script:isDragging   = $false
$script:dragStart    = $null
$script:dragEnd      = $null

# Parámetros de escala dinámicos para el lienzo
$script:scale        = 1.0
$script:xOffset      = 0
$script:yOffset      = 0

# ── Helpers de Coordenadas e Imagen ────────────────────────────────────────

function Get-CurrentDoc { return $script:docs[$script:currentTab] }

function Convert-RectToOriginal([System.Drawing.Rectangle]$r, $doc) {
    if ($script:scale -le 0) { return $r }
    $x = [int](($r.X - $script:xOffset) / $script:scale)
    $y = [int](($r.Y - $script:yOffset) / $script:scale)
    $w = [int]($r.Width / $script:scale)
    $h = [int]($r.Height / $script:scale)
    
    $ow = $doc.original.Width
    $oh = $doc.original.Height
    
    $x = [Math]::Max(0, [Math]::Min($x, $ow - 1))
    $y = [Math]::Max(0, [Math]::Min($y, $oh - 1))
    $w = [Math]::Max(1, [Math]::Min($w, $ow - $x))
    $h = [Math]::Max(1, [Math]::Min($h, $oh - $y))
    return [System.Drawing.Rectangle]::new($x, $y, $w, $h)
}

function Open-Image {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = "Seleccionar Imagen ($script:currentTab)"
    $dlg.Filter = "Archivos de Imagen|*.png;*.jpg;*.jpeg;*.bmp;*.webp;*.tiff"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    try {
        # Evitamos bloquear el archivo en disco usando un stream intermedio
        $stream = New-Object System.IO.FileStream($dlg.FileName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        $img = [System.Drawing.Image]::FromStream($stream)
        $stream.Close()
        $stream.Dispose()

        $doc = Get-CurrentDoc
        if ($doc.original) { $doc.original.Dispose() }
        if ($doc.work) { $doc.work.Dispose() }

        $doc.original = New-Object System.Drawing.Bitmap $img
        $doc.work     = New-Object System.Drawing.Bitmap $doc.original
        $img.Dispose()
        
        $doc.rects    = @()
        $doc.hasImage = $true
        $doc.path     = $dlg.FileName

        $listBox.Items.Clear()
        Update-Canvas
    } catch {
        [System.Windows.Forms.MessageBox]::Show("No se pudo abrir la imagen: $_", "Error")
    }
}

function Update-Canvas {
    $pb = $canvasPictureBox
    $doc = Get-CurrentDoc
    
    if (-not $doc.hasImage -or $null -eq $doc.work) {
        $bmp = New-Object System.Drawing.Bitmap [Math]::Max(1, $pb.Width), [Math]::Max(1, $pb.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::FromArgb(45,45,45))
        $font = New-Object System.Drawing.Font("Segoe UI", 12)
        $g.DrawString("Sin imagen cargada para la cara: $script:currentTab`n`nHaga clic en 'Abrir Imagen' para comenzar.", $font, [System.Drawing.Brushes]::Gray, 20, 20)
        $font.Dispose()
        $g.Dispose()
        if ($pb.Image) { $pb.Image.Dispose() }
        $pb.Image = $bmp
        return
    }

    $cw = $pb.ClientSize.Width
    $ch = $pb.ClientSize.Height
    if ($cw -le 0 -or $ch -le 0) { return }

    $iw = $doc.work.Width
    $ih = $doc.work.Height

    # Ajuste proporcional óptimo (Fit al canvas)
    $s = [Math]::Min($cw / $iw, $ch / $ih)
    if ($s -gt 1.0) { $s = 1.0 } # No sobre-escalar si es pequeña
    $script:scale = $s

    $nw = [int]($iw * $s)
    $nh = [int]($ih * $s)
    $script:xOffset = [int](($cw - $nw) / 2)
    $script:yOffset = [int](($ch - $nh) / 2)

    $bmp = New-Object System.Drawing.Bitmap $cw, $ch
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(35,35,35))
    
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($doc.work, $script:xOffset, $script:yOffset, $nw, $nh)

    # Dibujar rectángulos guardados sobre la vista previa
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 68, 68), 2.0)
    $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    foreach ($r in $doc.rects) {
        $g.DrawRectangle($pen, $r.X, $r.Y, $r.Width, $r.Height)
    }

    # Dibujar el rectángulo elástico que se está arrastrando en tiempo real
    if ($script:isDragging -and $script:dragStart -and $script:dragEnd) {
        $x1 = [Math]::Min($script:dragStart.X, $script:dragEnd.X)
        $y1 = [Math]::Min($script:dragStart.Y, $script:dragEnd.Y)
        $x2 = [Math]::Max($script:dragStart.X, $script:dragEnd.X)
        $y2 = [Math]::Max($script:dragStart.Y, $script:dragEnd.Y)
        $dragPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 200, 50), 2.0)
        $dragPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $g.DrawRectangle($dragPen, $x1, $y1, ($x2 - $x1), ($y2 - $y1))
        $dragPen.Dispose()
    }

    $pen.Dispose()
    $g.Dispose()

    if ($pb.Image) { $pb.Image.Dispose() }
    $pb.Image = $bmp
}

# ── Lógica de Aplicación de Efectos ────────────────────────────────────────

function Process-SingleBitmap($doc, $txt, $fontSize, $opacity, $wmColor, $posVal, $fillColor) {
    if (-not $doc.hasImage) { return $null }
    
    $resultBmp = New-Object System.Drawing.Bitmap $doc.original
    $g = [System.Drawing.Graphics]::FromImage($resultBmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # 1. Aplicar los borrados / tapados
    $brush = New-Object System.Drawing.SolidBrush $fillColor
    foreach ($r in $doc.rects) {
        $origRect = Convert-RectToOriginal $r $doc
        $g.FillRectangle($brush, $origRect)
    }
    $brush.Dispose()

    # 2. Aplicar Marca de Agua
    $fontObj = New-Object System.Drawing.Font ("Arial", $fontSize, [System.Drawing.FontStyle]::Bold)
    $alpha   = [int]($opacity * 2.55)
    $wmColorA = [System.Drawing.Color]::FromArgb($alpha, $wmColor.R, $wmColor.G, $wmColor.B)
    $wmBrush  = New-Object System.Drawing.SolidBrush $wmColorA

    $sf     = $g.MeasureString($txt, $fontObj)
    $tw     = $sf.Width
    $th     = $sf.Height
    $iw     = $resultBmp.Width
    $ih     = $resultBmp.Height
    $margin = [int]($fontSize * 0.5)

    if ($posVal -eq "diagonal-tiled") {
        $pad  = [int]($fontSize * 1.5)
        $cell = [int]([Math]::Max($tw, $th) + $pad)
        $tileBmp = New-Object System.Drawing.Bitmap $cell, $cell
        $tg = [System.Drawing.Graphics]::FromImage($tileBmp)
        $tg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $tg.DrawString($txt, $fontObj, $wmBrush, ($cell - $tw)/2, ($cell - $th)/2)
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
        $xy = $placements[$posVal]
        if (-not $xy) { $xy = $placements["bottom-right"] }
        $g.DrawString($txt, $fontObj, $wmBrush, $xy[0], $xy[1])
    }

    $fontObj.Dispose()
    $wmBrush.Dispose()
    $g.Dispose()

    return $resultBmp
}

function Apply-Effects {
    $doc = Get-CurrentDoc
    if (-not $doc.hasImage) {
        [System.Windows.Forms.MessageBox]::Show("Cargue una imagen en la pestaña actual primero.", "Aviso"); return
    }
    $txt = $watermarkText.Text.Trim()
    if (-not $txt) {
        [System.Windows.Forms.MessageBox]::Show("Por favor introduzca el texto de la marca de agua.", "Aviso"); return
    }

    # Procesar dinámicamente y actualizar la vista de trabajo
    $processed = Process-SingleBitmap $doc $txt $fontSizeTrack.Value $opacityTrack.Value $watermarkColorBtn.BackColor $posCombo.SelectedItem $fillColorBtn.BackColor
    if ($null -ne $processed) {
        if ($doc.work) { $doc.work.Dispose() }
        $doc.work = $processed
        Update-Canvas
        [System.Windows.Forms.MessageBox]::Show("Efectos aplicados visualmente al lienzo activo.`nPuede revisar el resultado antes de guardar.", "Listo")
    }
}

# ── Lógica de Guardado Avanzado ─────────────────────────────────────────────

function Save-Image {
    $docFront = $script:docs["Frontal"]
    $docBack  = $script:docs["Trasera"]

    if (-not $docFront.hasImage -and -not $docBack.hasImage) {
        [System.Windows.Forms.MessageBox]::Show("No hay ninguna imagen procesada para guardar.", "Aviso"); return
    }

    # Parámetros comunes de marca de agua y tapado
    $txt = $watermarkText.Text.Trim()
    $fontSize = $fontSizeTrack.Value
    $opacity = $opacityTrack.Value
    $wmColor = $watermarkColorBtn.BackColor
    $posVal = $posCombo.SelectedItem
    $fillColor = $fillColorBtn.BackColor

    # Preguntar si combinar si ambas caras existen
    $outputBmp = $null
    if ($docFront.hasImage -and $docBack.hasImage) {
        $ans = [System.Windows.Forms.MessageBox]::Show("Se han detectado ambas caras (Frontal y Trasera). ¿Desea combinarlas verticalmente en un solo archivo?`n`n[Sí] = Guardar ambas juntas`n[No] = Guardar solo la pestaña actual activa", "Exportar Documento", [System.Windows.Forms.MessageBoxButtons]::YesNoCancel)
        if ($ans -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            # Renderizar finales a máxima resolución nativa
            $finalFront = Process-SingleBitmap $docFront $txt $fontSize $opacity $wmColor $posVal $fillColor
            $finalBack  = Process-SingleBitmap $docBack $txt $fontSize $opacity $wmColor $posVal $fillColor

            $outW = [Math]::Max($finalFront.Width, $finalBack.Width)
            $outH = $finalFront.Height + $finalBack.Height + 20 # 20px de separación

            $outputBmp = New-Object System.Drawing.Bitmap $outW, $outH
            $g = [System.Drawing.Graphics]::FromImage($outputBmp)
            $g.Clear([System.Drawing.Color]::White)
            
            # Centrar horizontalmente si difieren de tamaño
            $g.DrawImage($finalFront, [int](($outW - $finalFront.Width)/2), 0)
            $g.DrawImage($finalBack, [int](($outW - $finalBack.Width)/2), ($finalFront.Height + 20))
            
            $g.Dispose()
            $finalFront.Dispose()
            $finalBack.Dispose()
        }
    }

    # Si decidió unitario o solo hay una cara activa
    if ($null -eq $outputBmp) {
        $activeDoc = Get-CurrentDoc
        if (-not $activeDoc.hasImage) {
            [System.Windows.Forms.MessageBox]::Show("La pestaña activa no contiene ninguna imagen.", "Error"); return
        }
        $outputBmp = Process-SingleBitmap $activeDoc $txt $fontSize $opacity $wmColor $posVal $fillColor
    }

    # Cuadro de diálogo Guardar como
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title  = "Guardar Imagen Resultante"
    $dlg.Filter = "PNG Imagen|*.png|JPEG Imagen|*.jpg"
    $dlg.DefaultExt = "png"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ext = [System.IO.Path]::GetExtension($dlg.FileName).ToLower()
        $fmt = if ($ext -eq '.jpg' -or $ext -eq '.jpeg') { [System.Drawing.Imaging.ImageFormat]::Jpeg } else { [System.Drawing.Imaging.ImageFormat]::Png }
        try {
            $outputBmp.Save($dlg.FileName, $fmt)
            [System.Windows.Forms.MessageBox]::Show("¡Guardado correctamente en:`n$($dlg.FileName)", "Éxito")
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error al guardar: $_", "Error")
        }
    }
    if ($outputBmp) { $outputBmp.Dispose() }
}

# ── Gestión de Selecciones Rectangulares ───────────────────────────────────

function Clear-Selections {
    $doc = Get-CurrentDoc
    $doc.rects = @()
    $listBox.Items.Clear()
    Update-Canvas
}

function Remove-Selected {
    if ($listBox.SelectedIndex -lt 0) { return }
    $idx = $listBox.SelectedIndex
    $doc = Get-CurrentDoc
    
    $doc.rects = @($doc.rects[0..($idx-1)] + $doc.rects[($idx+1)..($doc.rects.Count-1)])
    $listBox.Items.RemoveAt($idx)
    Update-Canvas
}

# ═══════════════════════════════════════════════════════════════════════════
# UI CONSTRUCCIÓN (DOCKING Y RESPONSIVE REPARADOS)
# ═══════════════════════════════════════════════════════════════════════════

$form = New-Object System.Windows.Forms.Form
$form.Text          = "Photo Eraser & Watermark Pro - Doble Cara"
$form.Size          = New-Object System.Drawing.Size(1250, 850)
$form.MinimumSize   = New-Object System.Drawing.Size(950, 650)
$form.StartPosition = "CenterScreen"

# Contenedor Base Horizontal split
$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = "Fill"
$mainLayout.ColumnCount = 2
$mainLayout.RowCount = 1
$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle "Percent" 100)) # Canvas amplio
$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle "Absolute" 290)) # Controles fijos derechos
$form.Controls.Add($mainLayout)

# PANEL IZQUIERDO: Pestañas + Lienzo
$leftContainer = New-Object System.Windows.Forms.Panel
$leftContainer.Dock = "Fill"
$mainLayout.Controls.Add($leftContainer, 0, 0)

# Selector de Cara (Tabs superiores)
$tabStrip = New-Object System.Windows.Forms.TabControl
$tabStrip.Dock = "Top"
$tabStrip.Height = 28
$tabStrip.TabPages.Add("Frontal", "Cara Frontal / Delantera")
$tabStrip.TabPages.Add("Trasera", "Cara Trasera / Posterior")
$tabStrip.Add_SelectedIndexChanged({
    $script:currentTab = if ($tabStrip.SelectedIndex -eq 1) { "Trasera" } else { "Frontal" }
    $listBox.Items.Clear()
    $doc = Get-CurrentDoc
    if ($doc.hasImage) {
        for ($i=0; $i -lt $doc.rects.Count; $i++) {
            [void]$listBox.Items.Add("Zona borrado #${i}")
        }
    }
    Update-Canvas
})
$leftContainer.Controls.Add($tabStrip)

# Canvas del PictureBox (Ocupa todo el resto del panel izquierdo)
$canvasPictureBox = New-Object System.Windows.Forms.PictureBox
$canvasPictureBox.Dock = "Fill"
$canvasPictureBox.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$canvasPictureBox.Cursor = "Cross"
$leftContainer.Controls.Add($canvasPictureBox)
$canvasPictureBox.BringToFront() # Obligatorio para quedar bajo las pestañas

# Eventos del Ratón corregidos para arrastre exacto en coordenadas visuales
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

    if ($w -gt 4 -and $h -gt 4) {
        $rectVisual = New-Object System.Drawing.Rectangle $x1, $y1, $w, $h
        $doc = Get-CurrentDoc
        $doc.rects += $rectVisual
        [void]$listBox.Items.Add("Zona borrado #${$doc.rects.Count-1}")
    }
    Update-Canvas
})
$canvasPictureBox.Add_Resize({ Update-Canvas })

# PANEL DERECHO: Controles (Panel con Scroll con márgenes limpios)
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.AutoScroll = $true
$panel.Padding = New-Object System.Windows.Forms.Padding(10)
$mainLayout.Controls.Add($panel, 1, 0)

$yPos = 10
function Add-GuiElement($obj, $hGap=4) {
    $obj.Location = New-Object System.Drawing.Point(10, $script:yPos)
    if ($obj.Width -eq 0) { $obj.Width = 250 }
    $panel.Controls.Add($obj)
    $script:yPos += $obj.Height + $hGap
}

function Add-GuiLabel($text, $bold=$false) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.AutoSize = $true
    if ($bold) { $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold) }
    Add-GuiElement $lbl 2
}

# --- Sección Imagen ---
Add-GuiLabel "Imagen ($script:currentTab)" $true
$openBtn = New-Object System.Windows.Forms.Button -Property @{Text="Abrir Imagen"; Height=28}
$openBtn.Add_Click({ Open-Image })
Add-GuiElement $openBtn

$saveBtn = New-Object System.Windows.Forms.Button -Property @{Text="GUARDAR RESULTADO FINAL"; Height=34; BackColor=[System.Drawing.Color]::LightGreen; Font=New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)}
$saveBtn.Add_Click({ Save-Image })
Add-GuiElement $saveBtn 15

# --- Sección Selecciones ---
Add-GuiLabel "Regiones Borradas" $true
$listBox = New-Object System.Windows.Forms.ListBox -Property @{Height=80}
Add-GuiElement $listBox

$removeBtn = New-Object System.Windows.Forms.Button -Property @{Text="Eliminar Seleccionado"; Height=25}
$removeBtn.Add_Click({ Remove-Selected })
Add-GuiElement $removeBtn

$clearBtn = New-Object System.Windows.Forms.Button -Property @{Text="Limpiar Todo"; Height=25}
$clearBtn.Add_Click({ Clear-Selections })
Add-GuiElement $clearBtn 15

# --- Sección Erase Method ---
Add-GuiLabel "Color de Censura / Tapado" $true
$fillColorBtn = New-Object System.Windows.Forms.Button -Property @{Text="Color de Relleno"; Height=25; BackColor=[System.Drawing.Color]::White}
$fillColorBtn.Add_Click({
    $cd = New-Object System.Windows.Forms.ColorDialog
    if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $fillColorBtn.BackColor = $cd.Color }
})
Add-GuiElement $fillColorBtn 15

# --- Sección Marca de Agua ---
Add-GuiLabel "Configuración Marca de Agua" $true

Add-GuiLabel "Texto:"
$watermarkText = New-Object System.Windows.Forms.TextBox -Property @{Text="COPIA RESTRINGIDA"}
Add-GuiElement $watermarkText

$fsLbl = New-Object System.Windows.Forms.Label -Property @{Text="Tamaño Letra: 45"; AutoSize=$true}
Add-GuiElement $fsLbl 0
$fontSizeTrack = New-Object System.Windows.Forms.TrackBar -Property @{Minimum=10; Maximum=150; Value=45; Height=30; TickFrequency=10}
$fontSizeTrack.Add_Scroll({ $fsLbl.Text = "Tamaño Letra: $($fontSizeTrack.Value)" })
Add-GuiElement $fontSizeTrack

$opLbl = New-Object System.Windows.Forms.Label -Property @{Text="Opacidad: 35%"; AutoSize=$true}
Add-GuiElement $opLbl 0
$opacityTrack = New-Object System.Windows.Forms.TrackBar -Property @{Minimum=5; Maximum=100; Value=35; Height=30; TickFrequency=10}
$opacityTrack.Add_Scroll({ $opLbl.Text = "Opacidad: $($opacityTrack.Value)%" })
Add-GuiElement $opacityTrack

Add-GuiLabel "Posición:"
$posCombo = New-Object System.Windows.Forms.ComboBox -Property @{DropDownStyle="DropDownList"}
$posCombo.Items.AddRange(@("top-left", "top-right", "bottom-left", "bottom-right", "center", "tiled", "diagonal-tiled"))
$posCombo.SelectedIndex = 6 # diagonal-tiled por defecto
Add-GuiElement $posCombo

Add-GuiLabel "Color Texto:"
$watermarkColorBtn = New-Object System.Windows.Forms.Button -Property @{Text="Elegir Color"; Height=25; BackColor=[System.Drawing.Color]::Red}
$watermarkColorBtn.Add_Click({
    $cd = New-Object System.Windows.Forms.ColorDialog
    if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $watermarkColorBtn.BackColor = $cd.Color }
})
Add-GuiElement $watermarkColorBtn 15

# --- Botón de Aplicar Efectos Visuales ---
$applyBtn = New-Object System.Windows.Forms.Button -Property @{Text="APLICAR EFECTOS AL LIENZO"; Height=38; Font=New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold); BackColor=[System.Drawing.Color]::LightSkyBlue}
$applyBtn.Add_Click({ Apply-Effects })
Add-GuiElement $applyBtn

# ── Atajos de Teclado y Lanzamiento ─────────────────────────────────────────
$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq 'O') { Open-Image; $_.SuppressKeyPress = $true }
    if ($_.Control -and $_.KeyCode -eq 'S') { Save-Image; $_.SuppressKeyPress = $true }
})
$form.KeyPreview = $true

[void]$form.ShowDialog()