# Roadmap — macverbs

Fonte de verdade das tarefas: **`docs/tasks/T*.md`** (frontmatter `status`).

Este arquivo é o índice humano. Agentes devem ler o arquivo da tarefa ativa e `AGENTS.md`.

## Como avançar

```bash
cd ~/work/Pessoal/macverbs
mise run tasks-list    # status de todas
mise run next          # próximo id pending (não manual)

# Loop recomendado: workflow do projeto
# implement-task com args: { "task": "T01" }
# ou { "task": "next" }
```

Ordem rígida sugerida:

`T01 → T02 → T03 → T04 → T05 → T06 → T07 → T08 → T09 → T10 → T11 → (T12 manual) → T13 → … → T25`

**MVP dogfood:** T01–T11 + T13–T16 (cal/rem + mail list/read/archive/delete).

## Fases

| Fase | Escopo | Tasks |
|------|--------|-------|
| 0 | Fundação (SPM, CLI contract, seams, CI, config) | T01–T05 |
| 1 | EventKit (Calendar + Reminders) | T06–T12 |
| 2 | Apple Events (Mail) | T13–T19 |
| 3 | Notes | T20 |
| 4 | Produto (doctor, completions, brew, dogfood, README) | T21–T25 |

## Decisões de produto (fixas)

| Tema | Decisão |
|------|---------|
| Escopo | Só Mail, Reminders, Notes, Calendar |
| Autor | Paulo (github.com/pfelrodrigues); produto se chama **macverbs** |
| Distro | Homebrew tap agora; core depois |
| Stack | Swift; performance, confiabilidade, testabilidade, segurança |
| Backend | **Híbrido:** EventKit (Calendar/Reminders) + Apple Events (Mail/Notes) |
| icalBuddy | Eliminado — reimplementar listagem em EventKit |
| Oracle de comportamento | `~/nix/clis/apple` até paridade |
| Não é | RemCTL-depth em Reminders; Graph/WA/TFS; GUI; afiliado à Apple |

## Status rápido

Rode `mise run tasks-list` (não duplique status aqui à mão).
