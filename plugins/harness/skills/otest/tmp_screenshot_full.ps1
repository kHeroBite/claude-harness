Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
$outPath = $args[0]
$bmp.Save($outPath)
Write-Output "saved:$outPath vs=$($vs.X),$($vs.Y),$($vs.Width),$($vs.Height)"
