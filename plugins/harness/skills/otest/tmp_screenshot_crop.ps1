Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$crop = New-Object System.Drawing.Rectangle(0, 0, 1290, 1125)
$bmp2 = $bmp.Clone($crop, $bmp.PixelFormat)
$outPath = $args[0]
$bmp2.Save($outPath)
Write-Output "saved:$outPath"
