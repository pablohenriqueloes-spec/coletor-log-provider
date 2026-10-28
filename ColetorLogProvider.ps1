#Requires -Version 3.0
<#
    Coletor de Log de Provider (BPrv230.exe)

    - Lista os clientes (pastas) do diretório base (padrão E:\Benner\Workers).
    - Botão do cliente "apertado" (vermelho): cria prvlogAAAAMMDD.do ao lado de cada BPrv230.exe
      encontrado na pasta do cliente, no servidor local e nos servidores remotos marcados.
    - Clicar de novo (verde): renomeia o .do (para o Provider parar de gravar) e zipa as pastas
      prvlogAAAAMMDD de todos os servidores em um único .zip, salvo dentro da pasta do cliente.
    - Clicar no nome do zip (ou Ctrl+C sobre ele) copia o arquivo para a área de transferência.

    Servidores remotos são acessados pelo compartilhamento administrativo:
    E:\Benner\Workers  ->  \\SERVIDOR\E$\Benner\Workers
#>
param(
    [string]$BaseDir = 'E:\Benner\Workers'
)

# Clipboard e WinForms precisam de STA
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', "`"$PSCommandPath`"", '-BaseDir', "`"$BaseDir`"")
    return
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem
[Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- configuração
$Servidores      = @('OCISCHVMI-JUR01', 'OCISCHVMI-JUR02', 'OCITSKVMI-JUR01')
$ExeProvider     = 'BPrv230.exe'
$ProfundidadeMax = 4    # níveis abaixo da pasta do cliente onde o BPrv230.exe é procurado
$EsperaSegundos  = 3    # espera após renomear o .do, para o Provider soltar os arquivos

$CorNeutra   = [Drawing.Color]::Gainsboro
$CorAtiva    = [Drawing.Color]::FromArgb(220, 53, 69)
$CorColetado = [Drawing.Color]::FromArgb(40, 167, 69)

# ---------------------------------------------------------------- estado
$Script:Coletas  = @{}   # cliente -> coleta ativa (nome do log + pontos onde o .do foi criado)
$Script:CacheExe = @{}   # "raiz|cliente" -> pastas onde está o BPrv230.exe
$Script:Linhas   = @{}   # cliente -> controles da linha
$Script:ChkServidores = @()

# ---------------------------------------------------------------- funções
function Write-Log([string]$Mensagem) {
    $txtLog.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Mensagem) + "`r`n")
}

function Wait-UI([int]$Segundos) {
    $fim = (Get-Date).AddSeconds($Segundos)
    while ((Get-Date) -lt $fim) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Convert-ParaUnc([string]$Servidor, [string]$Caminho) {
    if ($Caminho -match '^([A-Za-z]):\\?(.*)$') {
        return ('\\{0}\{1}$\{2}' -f $Servidor, $Matches[1], $Matches[2]).TrimEnd('\')
    }
    return $null
}

function Get-Alvos {
    $base = $txtBase.Text.Trim().TrimEnd('\')
    $alvos = @()
    if ($chkLocal.Checked) {
        $alvos += [pscustomobject]@{ Nome = $env:COMPUTERNAME; Raiz = $base; Local = $true }
    }
    foreach ($chk in $Script:ChkServidores) {
        if (-not $chk.Checked) { continue }
        $unc = Convert-ParaUnc $chk.Text $base
        if ($unc) {
            $alvos += [pscustomobject]@{ Nome = $chk.Text; Raiz = $unc; Local = $false }
        } else {
            Write-Log "Não foi possível montar o caminho remoto para $($chk.Text) (o diretório base precisa começar com letra de unidade)."
        }
    }
    return $alvos
}

function Search-Exe([string]$Pasta, [int]$Nivel) {
    try {
        if ([IO.File]::Exists([IO.Path]::Combine($Pasta, $ExeProvider))) { $Pasta }
        if ($Nivel -ge $ProfundidadeMax) { return }
        foreach ($sub in [IO.Directory]::GetDirectories($Pasta)) {
            # não desce nas pastas de log geradas pelo próprio Provider
            if ([IO.Path]::GetFileName($sub) -like 'prvlog*') { continue }
            Search-Exe $sub ($Nivel + 1)
        }
    } catch { }
}

function Find-PastasProvider($Alvo, [string]$Cliente) {
    $chave = "$($Alvo.Raiz)|$Cliente"
    if ($Script:CacheExe.ContainsKey($chave)) { return $Script:CacheExe[$chave] }
    $pastaCliente = Join-Path $Alvo.Raiz $Cliente
    if (-not [IO.Directory]::Exists($pastaCliente)) { return @() }
    $pastas = @(Search-Exe $pastaCliente 0)
    if ($pastas.Count) { $Script:CacheExe[$chave] = $pastas }
    return $pastas
}

function Get-ZipMaisRecente([string]$PastaCliente) {
    if (-not [IO.Directory]::Exists($PastaCliente)) { return $null }
    $zip = Get-ChildItem -LiteralPath $PastaCliente -Filter 'prvlog*.zip' -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($zip) { return $zip.FullName }
    return $null
}

function Set-ZipLinha([string]$Cliente, [string]$CaminhoZip) {
    $l = $Script:Linhas[$Cliente]
    $l.Zip = $CaminhoZip
    if ($CaminhoZip) {
        $l.Link.Text = [IO.Path]::GetFileName($CaminhoZip)
        $l.Link.LinkBehavior = 'AlwaysUnderline'
        $l.Link.Enabled = $true
        $l.BtnApagar.Enabled = $true
        $toolTip.SetToolTip($l.Link, "$CaminhoZip`r`nClique (ou Ctrl+C) para copiar o arquivo")
    } else {
        $l.Link.Text = '(nenhum zip)'
        $l.Link.Enabled = $false
        $l.BtnApagar.Enabled = $false
        $toolTip.SetToolTip($l.Link, '')
    }
}

function Set-EstadoBotao([string]$Cliente, [string]$Estado) {
    $chk = $Script:Linhas[$Cliente].Botao
    switch ($Estado) {
        'Ativo' {
            $chk.Checked = $true
            $chk.BackColor = $CorAtiva
            $chk.ForeColor = [Drawing.Color]::White
            $chk.Text = "● COLETANDO  -  $Cliente"
        }
        'Coletado' {
            $chk.Checked = $false
            $chk.BackColor = $CorColetado
            $chk.ForeColor = [Drawing.Color]::White
            $chk.Text = $Cliente
        }
        default {
            $chk.Checked = $false
            $chk.BackColor = $CorNeutra
            $chk.ForeColor = [Drawing.Color]::Black
            $chk.Text = $Cliente
        }
    }
    $chk.FlatAppearance.CheckedBackColor = $chk.BackColor
}

function Start-Coleta([string]$Cliente) {
    $alvos = @(Get-Alvos)
    if (-not $alvos.Count) {
        Write-Log 'Nenhum servidor marcado. Marque "Local" e/ou algum servidor remoto.'
        return $false
    }
    $nome = 'prvlog' + (Get-Date -Format 'yyyyMMdd')
    $pontos = New-Object System.Collections.ArrayList

    foreach ($alvo in $alvos) {
        $pastas = @(Find-PastasProvider $alvo $Cliente)
        if (-not $pastas.Count) {
            Write-Log "[$($alvo.Nome)] $($Cliente): $ExeProvider não encontrado em $(Join-Path $alvo.Raiz $Cliente)"
            continue
        }
        foreach ($pasta in $pastas) {
            $arqDo = Join-Path $pasta "$nome.do"
            try {
                if (-not [IO.File]::Exists($arqDo)) { [IO.File]::Create($arqDo).Dispose() }
                [void]$pontos.Add([pscustomobject]@{
                    Alvo = $alvo.Nome; Raiz = $alvo.Raiz; Local = $alvo.Local
                    Pasta = $pasta; ArqDo = $arqDo; PastaLog = (Join-Path $pasta $nome)
                })
                Write-Log "[$($alvo.Nome)] Criado $arqDo"
            } catch {
                Write-Log "[$($alvo.Nome)] ERRO ao criar $($arqDo): $($_.Exception.Message)"
            }
        }
    }

    if (-not $pontos.Count) { return $false }
    $Script:Coletas[$Cliente] = [pscustomobject]@{ Nome = $nome; Pontos = $pontos }
    return $true
}

function New-ZipColeta($Coleta, [string]$Cliente, [string]$CaminhoZip) {
    $total = 0
    $fs = New-Object IO.FileStream($CaminhoZip, [IO.FileMode]::CreateNew)
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($p in $Coleta.Pontos) {
            if (-not [IO.Directory]::Exists($p.PastaLog)) {
                Write-Log "[$($p.Alvo)] Pasta de log não encontrada: $($p.PastaLog)"
                continue
            }
            # dentro do zip: SERVIDOR\<servico>\<Provider>\prvlogAAAAMMDD\...
            $raizCliente = Join-Path $p.Raiz $Cliente
            $prefixo = $p.Alvo + '\' + $p.PastaLog.Substring($raizCliente.Length).TrimStart('\')
            $n = 0
            foreach ($arq in [IO.Directory]::GetFiles($p.PastaLog, '*', [IO.SearchOption]::AllDirectories)) {
                $rel = $arq.Substring($p.PastaLog.Length).TrimStart('\')
                $entrada = $zip.CreateEntry(($prefixo + '\' + $rel).Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
                $destino = $entrada.Open()
                try {
                    # FileShare ReadWrite: lê mesmo que o Provider ainda esteja com o arquivo aberto
                    $origem = New-Object IO.FileStream($arq, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]'ReadWrite, Delete'))
                    try { $origem.CopyTo($destino) } finally { $origem.Dispose() }
                    $n++
                } catch {
                    Write-Log "[$($p.Alvo)] Falha ao ler $($arq): $($_.Exception.Message)"
                } finally {
                    $destino.Dispose()
                }
                [Windows.Forms.Application]::DoEvents()
            }
            Write-Log "[$($p.Alvo)] $n arquivo(s) de $($p.PastaLog)"
            $total += $n
        }
    } finally {
        $zip.Dispose()
        $fs.Dispose()
    }
    if ($total -eq 0) {
        Remove-Item -LiteralPath $CaminhoZip -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $CaminhoZip
}

function Stop-Coleta([string]$Cliente) {
    $coleta = $Script:Coletas[$Cliente]
    if (-not $coleta) { return $null }
    $hora = Get-Date -Format 'HHmmss'

    # 1) quebra a extensão do .do para o Provider parar de gravar
    foreach ($p in $coleta.Pontos) {
        try {
            if ([IO.File]::Exists($p.ArqDo)) {
                $novo = "$($p.ArqDo)_$hora"
                [IO.File]::Move($p.ArqDo, $novo)
                Write-Log "[$($p.Alvo)] Renomeado para $([IO.Path]::GetFileName($novo))"
            }
        } catch {
            Write-Log "[$($p.Alvo)] ERRO ao renomear $($p.ArqDo): $($_.Exception.Message)"
        }
    }
    Wait-UI $EsperaSegundos

    # 2) zip salvo na pasta do cliente (preferência pelo servidor local)
    $ref = @($coleta.Pontos | Where-Object { $_.Local }) + @($coleta.Pontos) | Select-Object -First 1
    $pastaZip = Join-Path $ref.Raiz $Cliente
    $caminhoZip = Join-Path $pastaZip ('{0}_{1}_{2}.zip' -f $coleta.Nome, $Cliente, $hora)
    $resultado = $null
    try {
        $resultado = New-ZipColeta $coleta $Cliente $caminhoZip
    } catch {
        Write-Log "ERRO ao gerar zip: $($_.Exception.Message)"
    }

    # 3) limpeza: apaga (ou renomeia) a pasta de log e o .do renomeado,
    #    para uma nova coleta no mesmo dia começar limpa
    if ($resultado) {
        foreach ($p in $coleta.Pontos) {
            if ([IO.Directory]::Exists($p.PastaLog)) {
                $apagou = $false
                if ($chkApagarPasta.Checked) {
                    try {
                        [IO.Directory]::Delete($p.PastaLog, $true)
                        $apagou = $true
                        Write-Log "[$($p.Alvo)] Pasta de log apagada: $($p.PastaLog)"
                    } catch {
                        Write-Log "[$($p.Alvo)] Aviso: não foi possível apagar a pasta de log ($($_.Exception.Message))"
                    }
                }
                if (-not $apagou -and [IO.Directory]::Exists($p.PastaLog)) {
                    try { [IO.Directory]::Move($p.PastaLog, "$($p.PastaLog)_$hora") }
                    catch { Write-Log "[$($p.Alvo)] Aviso: não foi possível renomear a pasta de log ($($_.Exception.Message))" }
                }
            }
            if ($chkApagarDo.Checked) {
                try {
                    $doRenomeado = "$($p.ArqDo)_$hora"
                    if ([IO.File]::Exists($doRenomeado)) { [IO.File]::Delete($doRenomeado) }
                } catch {
                    Write-Log "[$($p.Alvo)] Aviso: não foi possível apagar o .do ($($_.Exception.Message))"
                }
            }
        }
        Write-Log "Zip gerado: $resultado"
    } else {
        Write-Log "$($Cliente): nenhum arquivo de log encontrado. O Provider estava em execução nessa pasta?"
    }

    $Script:Coletas.Remove($Cliente)
    return $resultado
}

function Copy-ZipClipboard([string]$Cliente) {
    $zip = $Script:Linhas[$Cliente].Zip
    if (-not $zip) { return }
    if (-not [IO.File]::Exists($zip)) {
        Write-Log "Arquivo não existe mais: $zip"
        Set-ZipLinha $Cliente $null
        return
    }
    $lista = New-Object System.Collections.Specialized.StringCollection
    [void]$lista.Add($zip)
    [Windows.Forms.Clipboard]::SetFileDropList($lista)
    Write-Log "Copiado para a área de transferência: $zip  (Ctrl+V para colar)"
}

function New-LinhaCliente([string]$Cliente) {
    $painel = New-Object Windows.Forms.Panel
    $painel.Size = New-Object Drawing.Size(1010, 36)
    $painel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)

    $chk = New-Object Windows.Forms.CheckBox
    $chk.Appearance = 'Button'
    $chk.AutoCheck = $false
    $chk.FlatStyle = 'Flat'
    $chk.FlatAppearance.BorderSize = 1
    $chk.TextAlign = 'MiddleLeft'
    $chk.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
    $chk.Location = New-Object Drawing.Point(4, 3)
    $chk.Size = New-Object Drawing.Size(380, 30)
    $chk.Tag = $Cliente
    $chk.Cursor = 'Hand'
    $chk.Add_Click({ Invoke-CliqueCliente $this.Tag })

    $link = New-Object Windows.Forms.LinkLabel
    $link.Location = New-Object Drawing.Point(394, 9)
    $link.Size = New-Object Drawing.Size(395, 20)
    $link.AutoEllipsis = $true
    $link.Tag = $Cliente
    $link.TabStop = $true
    $link.Add_Click({ $this.Focus(); Copy-ZipClipboard $this.Tag })
    $link.Add_KeyDown({
        if ($_.Control -and $_.KeyCode -eq 'C') { Copy-ZipClipboard $this.Tag; $_.Handled = $true }
    })

    $btn = New-Object Windows.Forms.Button
    $btn.Text = 'Apagar zip'
    $btn.Location = New-Object Drawing.Point(792, 4)
    $btn.Size = New-Object Drawing.Size(95, 28)
    $btn.Tag = $Cliente
    $btn.Add_Click({ Remove-ZipCliente $this.Tag })

    $btnLimpar = New-Object Windows.Forms.Button
    $btnLimpar.Text = 'Limpar antigos'
    $btnLimpar.Location = New-Object Drawing.Point(893, 4)
    $btnLimpar.Size = New-Object Drawing.Size(110, 28)
    $btnLimpar.Tag = $Cliente
    $btnLimpar.Add_Click({ Clear-Antigos $this.Tag })
    $toolTip.SetToolTip($btnLimpar, 'Apaga arquivos prvlog*.do antigos e pastas prvlog* que sobraram, nos servidores marcados')

    $painel.Controls.AddRange(@($chk, $link, $btn, $btnLimpar))
    $Script:Linhas[$Cliente] = [pscustomobject]@{ Painel = $painel; Botao = $chk; Link = $link; BtnApagar = $btn; Zip = $null }

    Set-EstadoBotao $Cliente 'Neutro'
    Set-ZipLinha $Cliente (Get-ZipMaisRecente (Join-Path $txtBase.Text.Trim().TrimEnd('\') $Cliente))
}

function Invoke-CliqueCliente([string]$Cliente) {
    $l = $Script:Linhas[$Cliente]
    $l.Botao.Enabled = $false
    $form.Cursor = 'WaitCursor'
    try {
        if ($Script:Coletas.ContainsKey($Cliente)) {
            Write-Log "=== $($Cliente): encerrando coleta ==="
            $zip = Stop-Coleta $Cliente
            Set-EstadoBotao $Cliente 'Coletado'
            if ($zip) { Set-ZipLinha $Cliente $zip }
        } else {
            Write-Log "=== $($Cliente): iniciando coleta ==="
            if (Start-Coleta $Cliente) {
                Set-EstadoBotao $Cliente 'Ativo'
            } else {
                Write-Log "$($Cliente): nenhum arquivo .do foi criado."
            }
        }
    } finally {
        $l.Botao.Enabled = $true
        $form.Cursor = 'Default'
        Update-Contador
    }
}

function Remove-ZipCliente([string]$Cliente) {
    $l = $Script:Linhas[$Cliente]
    if (-not $l.Zip) { return }
    $r = [Windows.Forms.MessageBox]::Show("Apagar o arquivo?`r`n`r`n$($l.Zip)", 'Apagar zip', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try {
        Remove-Item -LiteralPath $l.Zip -Force -ErrorAction Stop
        Write-Log "Apagado: $($l.Zip)"
        # mostra o próximo zip mais recente da mesma pasta, se houver
        Set-ZipLinha $Cliente (Get-ZipMaisRecente ([IO.Path]::GetDirectoryName($l.Zip)))
    } catch {
        Write-Log "ERRO ao apagar $($l.Zip): $($_.Exception.Message)"
    }
}

function Clear-Antigos([string]$Cliente) {
    if ($Script:Coletas.ContainsKey($Cliente)) {
        [void][Windows.Forms.MessageBox]::Show("Há uma coleta ativa para $Cliente. Encerre a coleta antes de limpar.", 'Limpar antigos', 'OK', 'Information')
        return
    }
    $alvos = @(Get-Alvos)
    if (-not $alvos.Count) { Write-Log 'Nenhum servidor marcado.'; return }

    $form.Cursor = 'WaitCursor'
    $itens = New-Object System.Collections.ArrayList
    try {
        foreach ($alvo in $alvos) {
            foreach ($pasta in @(Find-PastasProvider $alvo $Cliente)) {
                try {
                    # arquivos prvlog*.do e prvlog*.do_HHMMSS
                    foreach ($f in [IO.Directory]::GetFiles($pasta, 'prvlog*.do*')) {
                        if ([IO.Path]::GetFileName($f) -match '^prvlog\d{8}\.do(_.*)?$') {
                            [void]$itens.Add([pscustomobject]@{ Alvo = $alvo.Nome; Caminho = $f; Pasta = $false })
                        }
                    }
                    # pastas de log que sobraram (prvlogAAAAMMDD e prvlogAAAAMMDD_HHMMSS)
                    foreach ($d in [IO.Directory]::GetDirectories($pasta, 'prvlog*')) {
                        if ([IO.Path]::GetFileName($d) -match '^prvlog\d{8}(_.*)?$') {
                            [void]$itens.Add([pscustomobject]@{ Alvo = $alvo.Nome; Caminho = $d; Pasta = $true })
                        }
                    }
                } catch {
                    Write-Log "[$($alvo.Nome)] Não foi possível listar $($pasta): $($_.Exception.Message)"
                }
            }
        }
    } finally { $form.Cursor = 'Default' }

    if (-not $itens.Count) { Write-Log "$($Cliente): nenhum .do ou pasta de log antiga encontrada."; return }

    $lista = ($itens | Select-Object -First 25 | ForEach-Object {
        '[{0}] {1}{2}' -f $_.Alvo, $_.Caminho, $(if ($_.Pasta) { '  (pasta)' } else { '' })
    }) -join "`r`n"
    if ($itens.Count -gt 25) { $lista += "`r`n... e mais $($itens.Count - 25) item(ns)" }
    $r = [Windows.Forms.MessageBox]::Show("Apagar $($itens.Count) item(ns) antigos de $($Cliente)?`r`n`r`n$lista",
        'Limpar antigos', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }

    $form.Cursor = 'WaitCursor'
    try {
        foreach ($i in $itens) {
            try {
                if ($i.Pasta) { [IO.Directory]::Delete($i.Caminho, $true) } else { [IO.File]::Delete($i.Caminho) }
                Write-Log "[$($i.Alvo)] Apagado: $($i.Caminho)"
            } catch {
                Write-Log "[$($i.Alvo)] ERRO ao apagar $($i.Caminho): $($_.Exception.Message)"
            }
            [Windows.Forms.Application]::DoEvents()
        }
    } finally { $form.Cursor = 'Default' }
    if ($Script:Linhas[$Cliente].Botao.BackColor -eq $CorColetado) { Set-EstadoBotao $Cliente 'Neutro' }
}

function Update-Filtro {
    $texto = $txtPesquisa.Text.Trim().Replace('%', '*')
    $padrao = "*$texto*"
    $flow.SuspendLayout()
    foreach ($cliente in $Script:Linhas.Keys) {
        $visivel = $true
        if ($texto) {
            try { $visivel = $cliente -like $padrao }
            catch { $visivel = $cliente.IndexOf($texto, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        }
        $Script:Linhas[$cliente].Painel.Visible = $visivel
    }
    $flow.ResumeLayout()
    Update-Contador
}

function Update-Contador {
    $visiveis = @($Script:Linhas.Values | Where-Object { $_.Painel.Visible }).Count
    $lblContador.Text = '{0} de {1} clientes   |   coletas ativas: {2}' -f $visiveis, $Script:Linhas.Count, $Script:Coletas.Count
}

function Update-ListaClientes {
    $form.Cursor = 'WaitCursor'
    try {
        $Script:CacheExe = @{}
        $nomes = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $base = $txtBase.Text.Trim().TrimEnd('\')
        $raizes = @(Get-Alvos | ForEach-Object { $_.Raiz })
        if (-not $chkLocal.Checked) { $raizes = @($base) + $raizes }   # a lista sempre parte do diretório informado
        foreach ($raiz in $raizes) {
            [Windows.Forms.Application]::DoEvents()
            try {
                foreach ($d in [IO.Directory]::GetDirectories($raiz)) { [void]$nomes.Add([IO.Path]::GetFileName($d)) }
            } catch {
                Write-Log "Não foi possível listar $($raiz): $($_.Exception.Message)"
            }
        }
        # coletas em andamento continuam na lista mesmo que a pasta não apareça mais
        foreach ($c in $Script:Coletas.Keys) { [void]$nomes.Add($c) }

        $flow.SuspendLayout()
        $flow.Controls.Clear()
        foreach ($c in @($Script:Linhas.Keys)) {
            if (-not $nomes.Contains($c)) { $Script:Linhas[$c].Painel.Dispose(); $Script:Linhas.Remove($c) }
        }
        foreach ($c in $nomes) {
            if (-not $Script:Linhas.ContainsKey($c)) { New-LinhaCliente $c }
            $flow.Controls.Add($Script:Linhas[$c].Painel)
        }
        $flow.ResumeLayout()
        Write-Log "$($nomes.Count) cliente(s) carregado(s) de: $($raizes -join ', ')"
    } finally {
        $form.Cursor = 'Default'
        Update-Filtro
    }
}

# ---------------------------------------------------------------- interface
$form = New-Object Windows.Forms.Form
$form.Text = 'Coletor de Log de Provider'
$form.Size = New-Object Drawing.Size(1070, 760)
$form.MinimumSize = New-Object Drawing.Size(1070, 400)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.KeyPreview = $true

$toolTip = New-Object Windows.Forms.ToolTip

$topo = New-Object Windows.Forms.Panel
$topo.Dock = 'Top'
$topo.Height = 112

$lblBase = New-Object Windows.Forms.Label
$lblBase.Text = 'Diretório base:'
$lblBase.Location = New-Object Drawing.Point(10, 13)
$lblBase.AutoSize = $true

$txtBase = New-Object Windows.Forms.TextBox
$txtBase.Text = $BaseDir
$txtBase.Location = New-Object Drawing.Point(110, 10)
$txtBase.Size = New-Object Drawing.Size(360, 23)

$btnAtualizar = New-Object Windows.Forms.Button
$btnAtualizar.Text = 'Atualizar lista'
$btnAtualizar.Location = New-Object Drawing.Point(478, 8)
$btnAtualizar.Size = New-Object Drawing.Size(110, 27)
$btnAtualizar.Add_Click({ Update-ListaClientes })

$chkApagarPasta = New-Object Windows.Forms.CheckBox
$chkApagarPasta.Text = 'Apagar pasta de log após zipar'
$chkApagarPasta.Checked = $true
$chkApagarPasta.AutoSize = $true
$chkApagarPasta.Location = New-Object Drawing.Point(605, 12)

$chkApagarDo = New-Object Windows.Forms.CheckBox
$chkApagarDo.Text = 'Apagar .do após zipar'
$chkApagarDo.Checked = $true
$chkApagarDo.AutoSize = $true
$chkApagarDo.Location = New-Object Drawing.Point(820, 12)

$lblServ = New-Object Windows.Forms.Label
$lblServ.Text = 'Servidores:'
$lblServ.Location = New-Object Drawing.Point(10, 46)
$lblServ.AutoSize = $true

$chkLocal = New-Object Windows.Forms.CheckBox
$chkLocal.Text = "Local ($env:COMPUTERNAME)"
$chkLocal.Checked = $true
$chkLocal.AutoSize = $true
$chkLocal.Location = New-Object Drawing.Point(110, 44)
$topo.Controls.Add($chkLocal)

$x = 110 + $chkLocal.PreferredSize.Width + 20
foreach ($srv in $Servidores) {
    if ($srv -ieq $env:COMPUTERNAME) { continue }   # este servidor já é o "Local"
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $srv
    $c.AutoSize = $true
    $c.Location = New-Object Drawing.Point($x, 44)
    $c.Add_Click({ Update-ListaClientes })
    $toolTip.SetToolTip($c, "Acessa \\$srv\<unidade>$\... (compartilhamento administrativo)")
    $topo.Controls.Add($c)
    $Script:ChkServidores += $c
    $x += $c.PreferredSize.Width + 20
}
$chkLocal.Add_Click({ Update-ListaClientes })

$lblPesq = New-Object Windows.Forms.Label
$lblPesq.Text = 'Pesquisar:'
$lblPesq.Location = New-Object Drawing.Point(10, 80)
$lblPesq.AutoSize = $true

$txtPesquisa = New-Object Windows.Forms.TextBox
$txtPesquisa.Location = New-Object Drawing.Point(110, 77)
$txtPesquisa.Size = New-Object Drawing.Size(360, 23)
$txtPesquisa.Add_TextChanged({ Update-Filtro })
$toolTip.SetToolTip($txtPesquisa, 'Busca por parte do nome. Aceita * ou % como coringa (ex.: 040%Mar)')

$lblContador = New-Object Windows.Forms.Label
$lblContador.Location = New-Object Drawing.Point(480, 80)
$lblContador.AutoSize = $true
$lblContador.ForeColor = [Drawing.Color]::DimGray

$topo.Controls.AddRange(@($lblBase, $txtBase, $btnAtualizar, $chkApagarPasta, $chkApagarDo, $lblServ, $lblPesq, $txtPesquisa, $lblContador))

$flow = New-Object Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'
$flow.FlowDirection = 'TopDown'
$flow.WrapContents = $false
$flow.AutoScroll = $true
$flow.Padding = New-Object Windows.Forms.Padding(6)
$flow.BorderStyle = 'FixedSingle'

$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Dock = 'Bottom'
$txtLog.Height = 150
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Font = New-Object Drawing.Font('Consolas', 9)
$txtLog.BackColor = [Drawing.Color]::White

$form.Controls.Add($flow)
$form.Controls.Add($txtLog)
$form.Controls.Add($topo)
$flow.BringToFront()

$txtBase.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { Update-ListaClientes; $_.SuppressKeyPress = $true } })
$form.Add_KeyDown({ if ($_.Control -and $_.KeyCode -eq 'F') { $txtPesquisa.Focus(); $_.SuppressKeyPress = $true } })

$form.Add_Shown({ Update-ListaClientes; $txtPesquisa.Focus() })

$form.Add_FormClosing({
    if ($Script:Coletas.Count -eq 0) { return }
    $msg = "Existem $($Script:Coletas.Count) coleta(s) ativa(s):`r`n  $($Script:Coletas.Keys -join "`r`n  ")`r`n`r`n" +
           "Sim = encerrar e zipar todas antes de sair`r`nNão = sair e deixar os arquivos .do gravando`r`nCancelar = voltar"
    $r = [Windows.Forms.MessageBox]::Show($msg, 'Coletas ativas', 'YesNoCancel', 'Warning')
    if ($r -eq 'Cancel') { $_.Cancel = $true; return }
    if ($r -eq 'Yes') {
        foreach ($c in @($Script:Coletas.Keys)) { Invoke-CliqueCliente $c }
    }
})

[void]$form.ShowDialog()
