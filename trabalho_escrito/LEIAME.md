# Trabalho escrito (LaTeX, ABNT)

PDF pronto: `APS_Banco_de_Dados_Criticos.pdf`.

## Como compilar

Classe **abnTeX2** com **biblatex-abnt** (referências pela NBR 6023:2025 e citações pela NBR 10520:2023).
A bibliografia usa o **biber** (não o BibTeX).

```
latexmk -pdf main.tex
```

Ou, no TeXstudio/editor: pdflatex → biber → pdflatex → pdflatex
(no TeXstudio: Opções > Configurar > Compilar > "Ferramenta de bibliografia padrão" = Biber).

Pacotes usados: abntex2, biblatex-abnt, biber, helvet, txfonts, tikz, pgfplots, pgf-umlcd,
siunitx, tabularx, listings, csquotes. No MiKTeX eles instalam sozinhos na 1ª compilação.

## Estrutura

| Arquivo | Conteúdo |
|---|---|
| `main.tex` | Preâmbulo, capa, folha de rosto, listas e ordem dos capítulos |
| `config_citacoes.tex` | Ajuste das citações para a NBR 10520:2023 (sobrenome em maiúsculas e minúsculas) |
| `referencias.bib` | Referências conferidas em fonte primária |
| `capitulos/` | Um arquivo por capítulo |
| `figuras/` | Diagramas em TikZ (`.tex`), DER (`der.pdf`, gerado de `der.dot` com Graphviz) e telas (`.jpg`) |

Para regerar o DER: `dot -Tpdf figuras/der.dot -o figuras/der.pdf`.
