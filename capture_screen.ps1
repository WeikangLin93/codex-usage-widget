Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height
$g=[System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X,$b.Y,0,0,$b.Size)
$g.Dispose()
$p='C:\Users\45371\Desktop\codex-usage-widget\screen_check.png'
$bmp.Save($p,[System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output $p
