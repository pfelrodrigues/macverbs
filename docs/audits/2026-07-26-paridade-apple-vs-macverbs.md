# Auditoria de paridade: `apple` (oracle) × `macverbs` 0.1.0

Data: 2026-07-26 (America/Sao_Paulo)
Auditor: sessão Claude Code, host local (Mac do Paulo), execução **read-only**.

## Proveniência dos binários

| Item | Valor |
|---|---|
| `apple` | `/etc/profiles/per-user/pfelrodrigues/bin/apple` → wrapper nix `uv run --project ~/nix/clis/apple` (`~/nix/home/clis.nix:16`) |
| `macverbs` | `/opt/homebrew/bin/macverbs` → `Cellar/macverbs/0.1.0/bin/macverbs`, tap `pfelrodrigues/tap` |
| Fonte auditada | `~/work/Pessoal/macverbs/Sources/macverbs/` |
| Correspondência fonte×binário | **confirmada**: `git diff --stat v0.1.0 HEAD -- Sources Package.swift` vazio; `git diff --stat HEAD` vazio (worktree limpo nos arquivos versionados). A formula compila a tag `v0.1.0`. O `shasum` difere do `.build/release/macverbs` local apenas por build-path/flags. |

Todas as saídas empíricas abaixo vêm do binário brew 0.1.0 e do `apple` em PATH, na mesma sessão.

---

## 1. Resumo executivo

Superfície idêntica: 4 domínios, 22 verbos, todas as flags com os mesmos nomes, obrigatoriedade e defaults. Nada do `apple` está ausente. Chaves e tipos do JSON batem (uma chave aditiva em `reminders list`), e em oito comandos de leitura — incluindo `mail list`/`read` multi-conta com Exchange localizado — a saída é semanticamente idêntica após `jq -S`.

Performance: `reminders lists` cai de **17,7 s para 0,074 s** (~240×) e `calendar list --days 7` de 2,06 s para 0,075 s (~27×), trocando AppleScript/icalBuddy por EventKit. Extras: `doctor`, `--version`, completions geradas, erros em stderr.

Quatro bloqueadores, todos fora do Mail: **(1)** bug que inverte a data de 100% dos eventos all-day; **(2)** `calendars.json` não é lido do path do `apple`, e os rótulos de trabalho colapsam em `Calendário`; **(3)** a allowlist e a **ask-list** do Claude Code só conhecem `apple` — a confirmação de `mail delete` some sem erro; **(4)** o `email-cleanup` parseia o texto de `archive`/`delete` em português.

Divergências de contrato: erro de uso 2 × 64; erro em stdout/exit 1 × stderr/exit 1 ou 2; texto humano em inglês.

Nenhum é estrutural — (2), (3) e (4) são configuração e edição de skill; (1) é um `max()` numa linha. Veredito na seção 9.

---

## 2. Tabela de paridade domínio × verbo

Fonte: `apple <dom> <verbo> --help` e `macverbs <dom> <verbo> --help`, todos rodados nesta sessão.

### reminders

| Verbo | Flags `apple` | Flags `macverbs` | Status |
|---|---|---|---|
| `lists` | — | — | paridade |
| `list` | `--list` | `--list` | **parcial** — semântica de `--list` vazio difere (ver 4.4) |
| `add` | `title`, `--list --due --notes --priority {high,medium,low}` | idênticas | paridade (valor `list` no retorno difere: `(primeira)` × `(first)`) |
| `done` | `title`, `--list` | idênticas | paridade de superfície; alvo de `--list` vazio difere (ver 6.3) |
| `move` | `title`, `--from` req, `--to` req | idênticas | paridade |
| `edit` | `title`, `--list --due --priority {high,medium,low,none} --notes` | idênticas | paridade |
| `mklist` | `name` | `name` | paridade |
| `delete` | `title`, `--list` | idênticas | paridade de superfície; alvo de `--list` vazio difere (ver 6.3) |

### calendar

| Verbo | Flags `apple` | Flags `macverbs` | Status |
|---|---|---|---|
| `list` | `--days` (default 7, `cli.py:64`) | `--days` (default 7) | **parcial** — formato de `when` e rótulo `calendar` divergem (ver 4.1–4.3) |
| `add` | `title`, `--start` req, `--end` req, `--calendar` | idênticas | paridade de superfície (não executado) |

### notes

| Verbo | Flags `apple` | Flags `macverbs` | Status |
|---|---|---|---|
| `list` | `--folder` (default `Notes`, `cli.py:76`) | `--folder` (default `Notes`) | paridade |
| `read` | `title` | `title` | paridade (exit code em falha difere, ver 3) |
| `create` | `title`, `body`, `--folder` | idênticas | paridade de superfície (não executado) |
| `search` | `query` | `query` | paridade |

### mail

| Verbo | Flags `apple` | Flags `macverbs` | Status |
|---|---|---|---|
| `accounts` | — | — | paridade |
| `unread` | — | — | paridade |
| `list` | `--account`, `--limit` (20), `--mailbox {inbox,archive}` | idênticas | paridade (só `--limit` negativo difere, ver 5) |
| `read` | `message_id`, `--account` | idênticas | paridade |
| `archive` | `ids…`, `--account` req | idênticas | paridade por código; texto humano em inglês |
| `delete` | `ids…`, `--account` req | idênticas | paridade por código; texto humano em inglês |
| `attachments` | `message_id`, `--dest` req, `--account` | idênticas | paridade por código |
| `draft` | `message_id`, `--body-file` req, `--account`, `--attach` (repetível) | idênticas | paridade por código |
| `compose` | `--subject` req, `--body-file` req, `--to`, `--cc`, `--account` | idênticas | paridade por código |

### meta

| Verbo | `apple` | `macverbs` | Status |
|---|---|---|---|
| `doctor` | ausente | presente (TCC EventKit + Automation, sem prompt) | **extra** |
| `--version` | ausente (`apple --version` → exit 2) | `0.1.0`, exit 0 | **extra** |
| completions | fish escrita à mão (`~/nix/home/fish/completions/apple.fish`) | fish + zsh + bash geradas, instaladas pela formula | **extra** |

Nenhum verbo ou flag do `apple` está **ausente** no `macverbs`.

---

## 3. Contrato global

| Item | `apple` | `macverbs` | Veredito |
|---|---|---|---|
| Posição de `--json` | global, antes do subcomando | global, antes do subcomando (`CLIContract.swift:63` `peelLeading`) | paridade |
| `--json` depois do subcomando | exit **2** (argparse rejeita) | exit **0** — silenciosamente **ignorado**, imprime texto humano | **divergência** |
| Sucesso | exit 0 | exit 0 | paridade |
| Erro de domínio | exit 1, `erro: …` em **stdout** (`cli.py:271-272`) | exit 1, `error: …` em **stderr** | **divergência** |
| Falha de backend (AppleScript) | exit **1** (tudo cai no mesmo `except`) | exit **2** (`MacverbsError.system`) | **divergência** |
| Erro de uso | exit **2** (argparse) | exit **64** (`ExitCodes.usage`) | **divergência** |
| JSON | `json.dumps(indent=2, ensure_ascii=False)`, ordem de inserção | `JSONEncoder [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` | equivalente semanticamente |
| Estilo do JSON | `"name": "Inbox"` | `"name" : "Inbox"` (espaço antes do `:`) | cosmético; quebra comparação de string crua |
| Array vazio | `[]` | `[\n\n]` | cosmético; quebra `test "$out" = "[]"` |
| Timeout do osascript | 30 s (`osa.py:20`) | 30 s (`ScriptRunner.swift:284`) | **paridade** |
| Estouro do timeout | `subprocess.TimeoutExpired` **não** é capturado por `cli.py:270` → traceback no stderr, exit 1 | `MacverbsError.system("AppleScript timed out after 30s")` → exit 2 | divergência (macverbs melhor) |

Evidência dos exit codes (rodado nesta sessão):

```
apple bogus                 → 2      macverbs bogus                 → 64
apple mail archive x        → 2      macverbs mail archive x        → 64
apple --version             → 2      macverbs --version             → 0 (0.1.0)
apple mail accounts --json  → 2      macverbs mail accounts --json  → 0
    (saída verificada: "- iCloud | iCloud | paulo@… " — texto humano, a flag foi engolida)
apple --json notes read ZZ  → 1 (stdout "erro: …")
macverbs --json notes read ZZ → 2 (stderr "error: …")
apple --json mail read -- "-bogus"     → 1 (stdout "erro: mensagem -bogus não encontrada")
macverbs --json mail read -- "-bogus"  → 1 (stderr "error: message -bogus not found")
```

O `docs/behavior.md:19-25` afirma que 0/1/2/64 é o contrato "com paridade com o oracle". **Não é**: o oracle usa 2 para uso e 1 para *tudo* que falha, e escreve o erro em stdout. O contrato do macverbs é melhor (JSON puro no stdout, sistema distinguível de domínio), mas é um contrato **novo**, e a doc deveria dizer isso.

O timeout de 30 s é igual nos dois, então a regra de lote do `email-cleanup` ("batch de até ~25 IDs por chamada, fica sob o timeout de 30 s da CLI", `SKILL.md:133`) continua válida sem ajuste. Vale notar que os 17,7 s do `apple reminders lists` (seção 7) já rodavam a 59% desse teto — o macverbs remove essa margem apertada junto com o AppleScript.

O separador `--` funciona igual nos dois (`apple --json notes search -- "-abc"` e `macverbs --json notes search -- "-abc"`, ambos exit 0). Isso importa porque a skill `email-cleanup` depende dele (SKILL.md:126-130) para IDs que começam com `-`.

---

## 4. Diffs de JSON por domínio

Método: mesma invocação nos dois binários, comparação com `jq -S -c` (semântica) e `jq '[.[]|keys]|unique'` / `to_entries|map(.key+":"+(.value|type))` (chaves e tipos).

### 4.0 Idênticos (semanticamente iguais após `jq -S`)

| Comando | Resultado |
|---|---|
| `--json reminders lists` | **idêntico** (mesmos nomes, mesmas contagens, mesma ordem) |
| `--json mail accounts` | **idêntico** (7 contas, mesma ordem, `name/type/email`) |
| `--json mail unread` | **idêntico** (7 contas, `unread` inteiro) |
| `--json mail list --limit 3` | **idêntico** (21 registros, mesmos `id`, mesma ordem, `read` string) |
| `--json mail list --mailbox archive --limit 2` | **idêntico** (14 registros, mesmos `id`) |
| `--json mail read <id> --account iCloud` | **body idêntico**, inclusive os rótulos em português `De: / Assunto: / Data:` |
| `--json notes list --folder Notes` | **idêntico** (5 notas, `title/modified`) |
| `--json notes search "a"` | **idêntico** (5 notas, mesma ordem) |

### 4.1 reminders (item)

```
apple    keys: ["due","notes","priority","title"]
macverbs keys: ["due","list","notes","priority","title"]
```

`list` é **aditivo** (nome da lista de origem). Nenhum consumidor quebra. O texto humano também ganha ` | list: Inbox` por linha, que o `apple` não tem.

Tipos idênticos (`due`, `priority`, `notes`, `title` todos string; `priority` vazia quando 0). O mapa de prioridade é o mesmo (0 nenhuma, 1–4 high, 5 medium, 6–9 low) — `commands.py:22-31` × `Reminders.swift:74`.

### 4.2 calendar — `when`

Mesmas chaves (`calendar`, `title`, `when`), mesma contagem (17 eventos em `--days 2`, 44 em `--days 7`). O **valor** de `when` mudou de formato:

```
apple    "when": "day after tomorrow at 16:00 - 17:00"   ← texto relativo do icalBuddy
macverbs "when": "2026-07-28 at 16:00 - 17:00"           ← ISO absoluto
```

O `apple` devolve a primeira linha indentada da saída do icalBuddy (`icalbuddy.py:72-85`), que é texto humano e **relativo à data de execução** (`today`, `tomorrow`, `day after tomorrow`) para os 3 primeiros dias e absoluto depois. O `macverbs` sempre emite absoluto (`Calendar.swift:52-88`).

Tecnicamente o macverbs é superior — string estável, comparável, não depende de locale nem de quando o comando rodou. Mas é uma **quebra de valor**, não de shape.

### 4.3 calendar — rótulo `calendar`

```
apple    calendars: ["Evertec","Família Rodrigues","Vert","paulo@smartmonkeysbr.com"]
macverbs calendars: ["Calendário","Família Rodrigues","paulo@smartmonkeysbr.com"]
```

O `apple` lê o mapa UID→rótulo de `~/nix/clis/apple/calendars.json` (path fixo, `icalbuddy.py:17`). O `macverbs` lê de `~/.config/macverbs/calendars.json` ou `$MACVERBS_CONFIG_DIR` (`Config.swift:21-43`), e **esse diretório não existe no host** (`ls: /Users/pfelrodrigues/.config/macverbs/: No such file or directory`). Sem o mapa, todos os calendários de trabalho (que se chamam "Calendário" em várias contas) colapsam num rótulo só — exatamente a ambiguidade que o alias existe para desfazer.

**O arquivo é portável sem tradução.** Provado:

```
MACVERBS_CONFIG_DIR=~/nix/clis/apple macverbs --json calendar list --days 2
→ ["Evertec","Família Rodrigues","Vert","paulo@smartmonkeysbr.com"]   (idêntico ao apple)
```

Mesmo espaço de chaves (UID do EventKit), mesmo formato. É cópia de arquivo, não migração de dados.

### 4.4 reminders `list` sem `--list`

```
apple --json reminders list      → 4 itens  (só a lista Inbox)
macverbs --json reminders list   → 20 itens (todas as listas)
```

`scripts.py:44`: `target = f'list "{esc(list_name)}"' if list_name else "first list"` — o `apple` cai na **primeira lista** do Reminders.app quando `--list` é vazio, o que na prática é a Inbox e parece "o default" sem ser. O `macverbs` documenta e implementa "vazio = todas as listas" (`behavior.md:44`).

Mudança deliberada e melhor, mas quem chamar sem `--list` esperando 4 itens recebe 20.

### 4.5 Ordenação do `calendar list`

O `apple` agrupa por calendário (um `icalBuddy -ic <uid>` por calendário, `commands.py:101-105`); o `macverbs` ordena por data/hora e depois título (`Calendar.swift:95-101`). O conteúdo é o mesmo conjunto; a ordem do array difere. Só importa para quem consome posicionalmente — nenhuma skill faz isso.

---

## 5. Gaps blocantes

### B1. Todo evento all-day sai com data invertida

O mais grave e o mais fácil de corrigir.

```
macverbs --json calendar list --days 30 | jq '[.[]|select(.when|test("^[0-9-]+ - [0-9-]+$"))]'
→ 13 eventos, TODOS com o fim um dia antes do início:
  {"t":"Faxina semanal","when":"2026-07-27 - 2026-07-26"}
  {"t":"Dia dos Pais","when":"2026-08-09 - 2026-08-08"}
  {"t":"Aniversário Noemi","when":"2026-08-20 - 2026-08-19"}
  … (13/13)

apple, os mesmos eventos:
  {"t":"Faxina semanal","when":"tomorrow"}
  {"t":"Dia dos Pais","when":"2026-08-09"}
  {"t":"Aniversário Noemi","when":"2026-08-20"}
```

Causa em `Sources/macverbs/Calendar.swift:63-71`:

```swift
if isAllDay {
    // EventKit exclusive end → last inclusive day is end - 1 day.
    let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? end
```

A premissa "EventKit all-day end é exclusivo (meia-noite seguinte)" **não vale para os dados deste Mac**: o `endDate` vem no mesmo dia do início, então subtrair 24 h joga para o dia anterior e a comparação `startS == endS` nunca casa. Resultado: 100% dos all-day viram intervalo invertido, nenhum cai no caminho de dia único.

Os testes passam porque alimentam a premissa em vez de dados reais — `MacverbsTests.swift:1575-1583` (`calendarFormatWhenAllDaySingle`) passa `end = start + 1 dia` e espera `"2026-07-26"`. É um teste que confirma a suposição, não o comportamento.

Impacto no consumidor: `housekeeping` cria nota inbox com o `when` cru (`SKILL.md:161`) — aniversários e feriados entrariam no vault com data invertida.

Correção sugerida (não aplicada — esta auditoria não implementa): normalizar `lastDay` para `max(lastDay, start)`, ou derivar o último dia de `end` só quando `end` for exatamente meia-noite de um dia posterior a `start`.

### B2. `calendars.json` não é encontrado

Detalhado em 4.3. Sem o arquivo em `~/.config/macverbs/`, `Vert`, `Evertec` e `PYO` viram `Calendário`.

Consumidor concreto: `housekeeping/SKILL.md:162` decide `privacy: private` × `normal` pela pertinência de `calendar` a `{Família Rodrigues, iCloud, Gmail, Aniversários, Feriados, Birthdays}` × `{Vert, PYO, Evertec}`. Com tudo rotulado `Calendário`, nenhum evento de trabalho casa a lista de trabalho e todos caem no ramo errado. É vazamento de classificação de privacidade, não estética.

Resolve com uma cópia de arquivo (checklist, seção 7).

### B3. Allowlist e ask-list do Claude Code só conhecem `apple`

`~/nix/home/claude-code/permissions.nix:35-53` lista 18 entradas `Bash(apple …)` para verbos de leitura. `~/nix/home/claude-code.nix:23-28` põe `apple mail send/delete/archive`, `apple calendar add`, `apple reminders add/done` atrás de confirmação.

Nada disso cobre `macverbs`. Consequência dupla:

- **Leitura:** cada `macverbs --json mail list` vira prompt de permissão. Na prática o `email-cleanup` (que roda uma chamada por conta, em paralelo) fica inviável sem intervenção.
- **Escrita:** `macverbs mail delete` e `macverbs mail archive` **não estão** na ask-list. A proteção que existe hoje some silenciosamente na troca. Isso é o mais perigoso da migração — a ausência de uma regra não dá erro, só deixa de perguntar.

Verificado nesta sessão: a tentativa de rodar `apple mail archive …` (mesmo com conta inexistente, sem efeito possível) foi barrada pelo gate de permissão, confirmando que a ask-list está ativa hoje.

### B4. O `email-cleanup` parseia o texto de `archive`/`delete` em português

O `email-cleanup` chama `archive`/`delete` **sem** `--json` (`SKILL.md:129-130`) e lê a linha de retorno. É o **único** consumidor programático de texto humano dos verbos de escrita — o `housekeeping` não invoca `mail archive` nem `mail delete` em lugar nenhum (grep confirmado; seus verbos de escrita são só de reminders, tratados em 6.8).

| O que a skill espera | `apple` (`format.py`) | `macverbs` (`Mail.swift:904-914`) |
|---|---|---|
| `Vert: 8/8 arquivado(s)` | `f"{acct}: {moved}/{req} arquivado(s)"` | `"\(acct): \(moved)/\(req) archived"` |
| `PYO: 6/7 deletado(s) — 1 não saiu da inbox` | `" — {n} não saíram da inbox"` | `"; \(n) remaining in inbox"` |
| `Google: arquivar não é suportado nesta conta (Gmail)…` | PT | `"archive is not supported on this account (Gmail)…"` |
| `erro: …` no stdout com exit != 0 (`email-cleanup/SKILL.md:157`) | sim | não — `error: …` no **stderr** |

O `email-cleanup` Fase 6 soma `moved` por conta a partir dessas linhas e a Fase 5 detecta o `unsupported` do Gmail por elas. O JSON tem as mesmas chaves nos dois, então a saída de escape é usar `--json` — mas isso é edição de skill, não drop-in.

---

## 6. Gaps aceitáveis e workarounds

### 6.1 Formato de `when` (calendar)

Ver 4.2. O ISO absoluto é objetivamente melhor. O custo é pontual: `housekeeping/SKILL.md:160` deduplica eventos por `(title, when)` contra o scan anterior, então na primeira execução após a troca **todo evento parece novo** e vira nota inbox duplicada. Workaround: limpar `calendar.last_scan`/o cache de dedup no mesmo commit da troca, e aceitar um ciclo de ruído — ou fazer a troca logo após um housekeeping, quando a janela de 7 dias já está processada.

A doc da skill (`SKILL.md:161`) descreve o campo como "string livre do icalBuddy (ex.: `today at 14:00 - 15:00`)" e precisa ser atualizada de qualquer forma.

### 6.2 `reminders list` sem `--list`

Ver 4.4. Os dois consumidores conhecidos (`housekeeping/SKILL.md:187` e `:311-312`) **sempre** passam `--list`, então nenhum quebra. Só afeta uso interativo.

### 6.3 Alvo de `--list` vazio em `done`/`delete`/`edit`

`apple` usa `first list` do Reminders.app (`scripts.py:117,154,169`). `macverbs` usa `store.defaultCalendarForNewReminders()`, com fallback para a primeira lista (`Reminders.swift:466-481`).

Não são necessariamente a mesma lista: "primeira na ordem do app" e "lista default para novos lembretes" são configurações independentes. Em verbo destrutivo (`delete`) isso é diferença de alvo, não de formato.

**Não verificável sem escrita** e não verifiquei. O workaround é trivial e já é o hábito das skills: passar `--list` sempre. Reportado como risco, não como gap confirmado.

### 6.4 `--limit` negativo

```
apple    --json mail list --limit -1   → exit 0, []
macverbs --json mail list --limit -1   → exit 64 (ArgumentParser lê -1 como opção)
macverbs --json mail list --limit=-1   → exit 1, "error: --limit must be >= 0"
```

Nenhuma skill passa limite negativo. Cosmético.

### 6.5 `(primeira)` × `(first)`

`commands.py:53` devolve `{"list": "(primeira)"}` quando `--list` é vazio; `Reminders.swift:69` devolve `"(first)"`. Nenhum consumidor lê esse campo.

### 6.6 Estilo do JSON e array vazio

`"k" : v` × `"k": v`, `[\n\n]` × `[]`. Ambos JSON válido; `jq` trata igual. Só quebra comparação de string crua, que nenhuma skill faz.

### 6.7 Texto humano em inglês (fora de mail archive/delete)

`- Inbox (4 pending)` × `- Inbox (4 pendentes)`, `no events.` × `nenhum evento.`, etc. Cosmético para uso interativo; só B4 tem consumidor programático.

### 6.8 Texto dos mutadores de reminders no housekeeping

O `housekeeping` chama `reminders move`/`edit`/`done`/`add` sem `--json` (`SKILL.md:192-196`, `:637`, `:658`), e o retorno muda de `movido:`/`editado:`/`concluído:`/`criado:` para `moved:`/`edited:`/`done:`/`created:`. Exposição baixa: a skill não parseia essas strings — `SKILL.md:194` manda **re-listar a lista destino** e confirmar o título antes de contar como roteado, que é verificação de efeito real e independe do idioma da mensagem.

---

## 7. Riscos

| # | Risco | Severidade | Nota |
|---|---|---|---|
| R1 | Ask-list de escrita não migra junto (B3) | **alta** | `macverbs mail delete/archive` roda sem confirmação. Falha silenciosa: nada erra, só para de perguntar. |
| R2 | `--list` vazio mira lista diferente em `done`/`delete` (6.3) | média | Verbo destrutivo, divergência não verificada. Mitigar sempre passando `--list`. |
| R3 | Erro vai pro stderr, exit 2 em vez de 1 | média | `email-cleanup/SKILL.md:157` procura `erro:` no stdout para decidir retry. Com macverbs o stdout fica vazio e a skill pode ler "sem erro". |
| R4 | `--json` pós-subcomando é ignorado em silêncio | média | `apple` erra com exit 2; `macverbs` retorna texto humano com exit 0. Um agente que erre a posição da flag recebe texto e tenta parsear como JSON. |
| R5 | Cobertura de teste é sintética nos all-day (B1) | média | 253 `@Test` e a suíte passa, mas os testes de calendário codificam a premissa errada. Vale um teste com `end == start`. |
| R6 | Verbos de escrita não executados nesta auditoria | média | `mail archive/delete/draft/compose`, `calendar add`, `notes create`, todos os mutadores de reminders: avaliados **só** por código, help e testes unitários, conforme restrição. Paridade de escrita é inferida, não medida. |
| R7 | `icalBuddy` deixa de ser exercitado | baixa | `~/nix/modules/darwin/homebrew.nix:20` instala `ical-buddy` com o comentário "binário assinado mantém o grant TCC da CLI apple". Se o `apple` sair, avaliar se remover o brew afeta algum grant residual. |
| R8 | Divergência de exit code de uso (2 × 64) | baixa | Nenhum consumidor atual ramifica em exit code de uso, mas `docs/behavior.md:22` afirma paridade onde não há. |
| R9 | TCC | **baixa — já resolvido** | `macverbs doctor` reporta `calendar: fullAccess`, `reminders: fullAccess`, `mail: authorized`. `notes: notRunning` só significa que o Notes.app não estava aberto; `notes list` e `notes search` funcionaram normalmente na mesma sessão. |

### Performance (a favor da troca)

| Comando | `apple` | `macverbs` | Fator |
|---|---|---|---|
| `notes --help` (startup) | 0,176 s | 0,010 s | 18× |
| `--json reminders lists` | **17,711 s** | 0,074 s | ~240× |
| `--json calendar list --days 7` | 2,063 s | 0,075 s | 27× |
| `--json mail accounts` | 0,532 s | 0,549 s | empate (ambos via osascript) |
| `--json mail unread` | 1,316 s | 1,146 s | empate |
| `--json mail list --limit 3` | 2,032 s | 1,801 s | empate |

O padrão é claro: onde o macverbs troca AppleScript por EventKit (reminders, calendar) o ganho é de ordens de grandeza; onde os dois usam Apple Events (mail, notes) o tempo é o mesmo, porque o gargalo é o Mail.app. Os 17,7 s do `apple reminders lists` vêm do laço AppleScript item-a-item em `scripts.py:28-33` — é a diferença entre um comando usável e um que estoura timeout de skill.

### Cobertura de teste dos verbos de escrita

253 `@Test` num arquivo só (`Tests/macverbsTests/MacverbsTests.swift`, 4.971 linhas), contra 151 testes em 6 arquivos no `apple`. Os comportamentos críticos **estão** cobertos:

- Gmail archive: `mailMoveArchiveGmailUnsupported`, `mailArchiveGmailReportsUnsupported`, `mailArchiveGmailUnsupportedJsonOmitsNullUnsupportedKeyShape`
- Draft sem abrir janela + `delay` por anexo: `mailScriptsDraftReplyWithoutOpeningWindow`, `mailScriptsDraftReplyWithAttachmentsDelays`
- Compose nunca envia: `mailScriptsComposeNewDraftNeverSends`
- Recontagem de `moved`/`remaining`: `mailDeleteCommandWithRemainingText`, `mailArchiveCommandJsonOnStdout`
- Ciclos de mutação de reminders: `remindersCliAddDoneCycle`, `remindersCliAddDeleteCycle`, `mockReminderMoveBetweenLists`, `mockReminderMklistIdempotent`

O único buraco material é o dos all-day (R5).

---

## 8. Checklist de substituição

Ordem importa: 1–3 antes de qualquer troca de PATH.

1. **Corrigir o all-day** (`Calendar.swift:65`): garantir que `lastDay` nunca seja anterior a `start`. Adicionar teste com `end == start` e com `end == start + 1 dia`, para cobrir os dois comportamentos de EventKit. Revalidar com `macverbs --json calendar list --days 30 | jq '[.[]|select(.when|test("^[0-9-]+ - [0-9-]+$"))]'` — deve voltar só multi-dia legítimo.
2. **Instalar o `calendars.json`**: `mkdir -p ~/.config/macverbs && cp ~/nix/clis/apple/calendars.json ~/.config/macverbs/`. Melhor: gerenciar pelo nix (`home.file.".config/macverbs/calendars.json"`) para não ficar fora do dotfiles. Conferir com `macverbs --json calendar list --days 2 | jq '[.[]|.calendar]|unique'` — precisa mostrar `Vert`/`Evertec`.
3. **Permissões do Claude Code**:
   - `~/nix/home/claude-code/permissions.nix`: duplicar as 18 entradas de leitura para `Bash(macverbs …)`, incluindo as variantes com `--json`.
   - `~/nix/home/claude-code.nix:23-28`: espelhar a ask-list — `Bash(macverbs mail delete*)`, `Bash(macverbs mail archive*)`, `Bash(macverbs calendar add*)`, `Bash(macverbs reminders add*)`, `Bash(macverbs reminders done*)`. **Fazer isto antes de o binário virar o caminho padrão**, não depois.
4. **Atualizar `email-cleanup/SKILL.md`** (16 menções a `apple `, das quais 5 são linhas de comando executáveis: `:40`, `:56`, `:64`, `:129`, `:130`):
   - trocar `apple` por `macverbs` em todas elas;
   - passar `--json` em `archive`/`delete` e ler `moved`/`requested`/`remaining`/`unsupported` do JSON em vez das strings em português (Fases 5 e 6);
   - corrigir a nota de erro (linha 157): `error: …` no **stderr**, exit 1 (domínio) ou 2 (backend);
   - atualizar as duas menções a "`~/nix/clis/apple`, `uv run pytest` exige 100% de cobertura" (linhas 10 e 159) para o repo e o comando do macverbs.
5. **Atualizar `housekeeping/SKILL.md`** (18 menções a `apple `): trocar todas; reescrever a descrição de `when` (`:161`) para o formato ISO; trocar a referência a `~/nix/clis/apple/calendars.json` (`:157`) pelo novo path; limpar o estado de dedup de calendário no mesmo commit (ver 6.1).
6. **PATH**: um alias `apple` → `macverbs` **não é suficiente** e é ativamente enganoso — as skills invocam por nome dentro de `Bash`, onde alias de fish não vale, e o prefix-match da allowlist casa o texto literal do comando, não o alvo do alias. Trocar as invocações nas skills (passos 4 e 5) é o caminho; manter o `apple` em PATH em paralelo durante o período de convivência.
7. **Completions**: a formula já instala fish/zsh/bash. Quando o `apple` sair, remover `~/nix/home/fish.nix:59` e o arquivo `~/nix/home/fish/completions/apple.fish`.
8. **Convivência e desligamento**: rodar os dois em paralelo por um ciclo de housekeeping completo, comparando as saídas dos comandos de leitura. Só então remover `(mkCli "apple" "apple")` de `~/nix/home/clis.nix:16`. Reavaliar o brew `ical-buddy` (`~/nix/modules/darwin/homebrew.nix:20`) — R7.
9. **Corrigir `docs/behavior.md`**:
   - seção Global (linhas 19-25): diz que os exit codes têm paridade com o oracle; não têm (oracle: 2 para uso, 1 para tudo, erro em stdout). Documentar como contrato deliberadamente novo;
   - exemplos de message-id (`:337`, `:422`, `:466`) mostram `"<msg1@example.com>"` com colchetes angulares. Os dois CLIs emitem o valor **cru, sem colchetes** — verificado nesta sessão (`"VERTANALYTICS-ONS/…@github.com"`, `"0100019f9f94a57d-3daab…"`). O comportamento tem paridade; só o exemplo da doc engana quem for montar um ID à mão.

---

## 9. Veredito

### `substitui com ressalvas`

**Não trocar o PATH nem as invocações das skills antes de completar os passos 1–5 do checklist.** As ressalvas não são estéticas: enquanto o passo 3 não for feito, `macverbs mail delete` e `macverbs mail archive` rodam **sem pedir confirmação**, porque a ask-list de hoje casa o texto literal `apple …`. A ausência de uma regra de permissão não gera erro — só silêncio.

Feitos os passos 1–5, a recomendação vira `substitui`.

O `macverbs` cobre 100% da superfície do `apple` — nenhum verbo, nenhuma flag, nenhum default fora do lugar — e reproduz exatamente os dados nos oito comandos de leitura mais usados, incluindo o domínio mais delicado (Mail multi-conta com Exchange localizado e IMAP), até no detalhe dos rótulos em português do corpo da mensagem. As chaves e os tipos do JSON batem, os comportamentos críticos do oracle estão portados com fidelidade (recusa honesta do archive no Gmail, recontagem embutida do `moved`, `reply without opening window` com `delay` por anexo, nunca enviar) e cobertos por testes nomeados. E é entre uma e duas ordens de grandeza mais rápido onde importa: os 17,7 s do `reminders lists` viram 0,074 s.

Não é `substitui` liso hoje por quatro coisas, todas conhecidas e todas fora do Mail:

1. o bug de all-day inverte a data de 13 em 13 eventos (B1) — é uma linha de código e um teste;
2. o `calendars.json` não está no lugar novo (B2) — é um `cp`, e provei que o arquivo é portável sem tradução;
3. o `email-cleanup` lê o texto de `archive`/`delete` em português e espera `erro:` no stdout (B4) — é edição de skill, com o JSON já pronto para receber;
4. a allowlist e a ask-list do Claude Code só conhecem `apple` (B3) — o item que mais preocupa, pelo motivo dito acima.

Nenhum é estrutural, e o ganho de latência sozinho já justifica a troca.

Ressalva de escopo, para não ler mais do que este relatório mediu: os verbos de escrita (`mail archive/delete/draft/compose`, `calendar add`, `notes create`, todos os mutadores de reminders) foram avaliados por código, `--help` e testes unitários, conforme a restrição de não executar escrita em dados reais. A paridade de escrita é inferida com boa evidência, não medida. Uma validação controlada — conta de teste, lista de reminders sintética — antes de desligar o `apple` seria prudente, e é a única lacuna que este método não conseguiu fechar.
