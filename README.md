# Coletor de Log de Provider

## Como usar
1. Copie `ColetorLogProvider.ps1` e `ColetorLogProvider.bat` para a mesma pasta no servidor.
2. Dê duplo clique no `.bat` (ou rode `powershell -ExecutionPolicy Bypass -File ColetorLogProvider.ps1`).
   Para outro diretório base: `ColetorLogProvider.bat -BaseDir "D:\Benner\Workers"` (ou altere no campo da tela e tecle Enter).
3. Marque **Local** e/ou os servidores remotos e clique no cliente:
   - **Vermelho (apertado)**: criou `prvlogAAAAMMDD.do` ao lado de cada `BPrv230.exe` do cliente, em cada servidor marcado.
   - **Verde**: renomeou o `.do` para `.do_HHMMSS`, esperou 3 s e zipou as pastas `prvlogAAAAMMDD` de todos os servidores em um único zip, salvo na pasta do cliente (`E:\Benner\Workers\<cliente>\prvlogAAAAMMDD_<cliente>_HHMMSS.zip`). Depois de zipar, a pasta de log e o `.do` renomeado são apagados (opções **Apagar pasta de log após zipar** e **Apagar .do após zipar** no topo, ligadas por padrão). Se a pasta não puder ser apagada (arquivo preso), ela é renomeada para `prvlogAAAAMMDD_HHMMSS`.
4. Clique no nome do zip (ou Ctrl+C com ele selecionado) para copiar o arquivo; depois é só Ctrl+V no Explorer, Teams, e-mail etc.
5. **Apagar zip** remove o zip mostrado (pede confirmação) e passa a mostrar o próximo mais recente, se houver.
6. **Limpar antigos** procura, nos servidores marcados, arquivos `prvlogAAAAMMDD.do` / `.do_HHMMSS` e pastas `prvlog*` que sobraram ao lado do `BPrv230.exe` do cliente, mostra a lista e apaga após confirmação. Fica bloqueado enquanto o cliente estiver com coleta ativa.

Pesquisa: busca por parte do nome; aceita `*` ou `%` como coringa (ex.: `040%Mar`). Ctrl+F vai para a pesquisa.

## Servidores remotos
O acesso é pelo compartilhamento administrativo: `E:\Benner\Workers` vira `\\SERVIDOR\E$\Benner\Workers`.
Requisitos: o usuário que roda a ferramenta precisa ser administrador nos servidores remotos e o compartilhamento `E$` precisa estar ativo (padrão no Windows Server).
Teste rápido: `dir \\OCISCHVMI-JUR02\E$\Benner\Workers` no prompt.

Se o `E$` for bloqueado, a alternativa é PowerShell Remoting (`Invoke-Command -ComputerName ...`) ou criar um compartilhamento normal da pasta Workers.

O servidor onde a ferramenta está rodando aparece como "Local" e não é listado de novo como remoto.

## Configurações (topo do .ps1)
- `$Servidores`: lista de servidores remotos.
- `$ProfundidadeMax`: quantos níveis abaixo da pasta do cliente procurar o `BPrv230.exe` (padrão 4).
- `$EsperaSegundos`: espera entre renomear o `.do` e zipar (padrão 3).

## Observações
- Ao fechar a janela com coletas ativas, a ferramenta pergunta se deve encerrar e zipar todas.
- Se a ferramenta for fechada sem encerrar, o `.do` continua lá e o Provider continua gravando; basta renomear/apagar o `.do` manualmente.
- Se um cliente tiver mais de um `BPrv230.exe` (ex.: `Provider` e `ProviderX86`), o `.do` é criado em todos, e o zip separa por `SERVIDOR\<serviço>\<pasta do provider>\`.
- Requer Windows PowerShell 3.0+ e .NET 4.5+ (já presentes no Windows Server 2012 R2 em diante).
