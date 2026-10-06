# Superfície de poder observada (cicle 2A)

Taula generada des de `results/power-surface.csv` pel simulador determinista
(`analysis/baselines.py`); no està escrita a mà. Cada cel·la és el resultat
observat d'intentar l'operació amb aquell actor sobre un estat mínim nou
(delegació activa dins d'abast, saldo sense usar). Només el model D es
contrasta també amb les proves Foundry (`results/dart-sequence-map.csv`).

| Model | Actor | Concedir | Revocar | Executar |
|---|---|---|---|---|
| A · Revocació només per l'usuari | usuari | sí | sí | no |
| A · Revocació només per l'usuari | agent | no | no | sí |
| A · Revocació només per l'usuari | extern | no | no | no |
| B · Credencial de curta durada | usuari | sí | sí | no |
| B · Credencial de curta durada | agent | no | no | sí |
| B · Credencial de curta durada | extern | no | no | no |
| C · Administrador central | usuari | sí | sí | no |
| C · Administrador central | agent | no | no | sí |
| C · Administrador central | administrador | sí | sí | sí |
| C · Administrador central | extern | no | no | no |
| D · Guardià DART | usuari | sí | sí | no |
| D · Guardià DART | agent | no | no | sí |
| D · Guardià DART | guardià | no | sí | no |
| D · Guardià DART | extern | no | no | no |

Lectura: el guardià de D només pot revocar; l'administrador de C pot concedir,
revocar i executar (arquetip explícit, no descripció de tots els sistemes
centralitzats). Cap fila afirma seguretat universal.
