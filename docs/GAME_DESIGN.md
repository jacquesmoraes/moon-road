# Projeto: viagem de carro da Terra até a Lua

## 1. Conceito

O jogo é uma road trip de longa duração em tempo real por uma estrada impossível que conecta a Terra à Lua.

O jogador começa na Terra com um carro simples e precisa percorrer aproximadamente 384.400 km até chegar à Lua.

A viagem deve levar semanas ou meses reais, dependendo do ritmo escolhido pelo jogador, upgrades realizados e tempo efetivamente dedicado à viagem.

O objetivo do jogo não é chegar rapidamente ao destino.

O principal objetivo é experimentar a própria viagem.

O jogador deve sentir que está realmente se afastando da Terra ao longo de dias, semanas e meses.

A estrada funciona como eixo central de um mundo formado por:

- paisagens exuberantes;
- cidades;
- postos;
- oficinas;
- motéis;
- restaurantes;
- estações;
- áreas abandonadas;
- estradas secundárias;
- locais secretos;
- pequenas comunidades;
- eventos;
- NPCs;
- sidequests;
- recursos;
- crafting;
- exploração.

A inspiração de ritmo vem de jogos como Stardew Valley e Graveyard Keeper: progressão constante, pequenos objetivos, exploração, crafting, NPCs e tarefas locais.

Visualmente, o jogo possui identidade retrofuturista/retrowave, mas deve evitar depender exclusivamente de neon rosa e azul.

---

# 2. Princípio central

A regra mais importante do projeto é:

**A viagem importa mais do que o destino.**

O jogador nunca deve sentir que está apenas esperando um contador chegar a zero.

Cada trecho deve transmitir:

- distância;
- passagem do tempo;
- isolamento;
- descoberta;
- evolução;
- curiosidade;
- contemplação.

O jogo também não deve bombardear o jogador com eventos constantemente.

Trechos longos de tranquilidade fazem parte da experiência.

A estrutura ideal é:

calmaria → paisagem → curiosidade → descoberta → exploração → recompensa → retorno à estrada.

---

# 3. Escala

Distância aproximada:

384.400 km.

A distância exibida ao jogador deve representar a viagem real.

Exemplo:

82.452 / 384.400 km

Entretanto, o mundo não precisa conter fisicamente 384 mil quilômetros modelados manualmente.

A estrada deve ser gerada através de:

- segmentos;
- chunks;
- módulos;
- elementos procedurais;
- pontos de interesse previamente definidos;
- regiões visuais.

O sistema deve permitir que uma coordenada lógica da viagem corresponda a qualquer distância, independentemente do tamanho físico da cena carregada.

---

# 4. Ritmos de viagem

O jogo deve permitir diferentes ritmos para jogadores que não desejam passar vários meses na campanha.

Não tratar como dificuldade tradicional.

Exemplo:

## Contemplativo

Velocidade base baixa.

Viagem pode durar vários meses ou quase um ano.

## Jornada

Experiência pretendida.

Algo próximo de 100 km/h de velocidade média inicial.

Viagem teórica de aproximadamente 160 dias sem upgrades ou paradas.

## Rápido

Velocidades maiores.

Campanha de algumas dezenas de dias.

## Personalizado

Jogador define multiplicador da velocidade de progresso.

A escolha altera ritmo, não conteúdo.

---

# 5. Jogabilidade da estrada

O jogador pode dirigir manualmente.

Controles devem ser simples e acessíveis.

O jogo não é um simulador automobilístico.

A condução deve transmitir prazer e fluidez.

Controles básicos:

- acelerar;
- frear;
- virar;
- faróis;
- buzina;
- rádio;
- cruise control;
- câmera.

O jogador deve conseguir passar muito tempo simplesmente dirigindo.

---

# 6. Modo Viagem

Uma das principais mecânicas.

O jogador pode ativar o Modo Viagem e permitir que o carro conduza sozinho enquanto o jogo permanece aberto.

O objetivo é permitir que o jogo seja usado quase como um vídeo de viagem ou ambience no segundo monitor.

Durante o Modo Viagem:

- veículo segue a estrada;
- velocidade selecionada é mantida;
- interface praticamente desaparece;
- rádio continua tocando;
- câmeras podem mudar automaticamente;
- cenário continua sendo simulado normalmente.

O jogador pode interromper o modo instantaneamente.

A intenção é produzir a sensação:

“Eu estava apenas deixando a viagem acontecer e vi alguma coisa interessante. Quero investigar.”

Essa transição entre contemplação passiva e exploração ativa é uma das principais identidades do jogo.

---

# 7. Câmeras do Modo Viagem

Possíveis câmeras:

- terceira pessoa tradicional;
- câmera traseira cinematográfica;
- câmera distante;
- capô;
- cockpit;
- banco do passageiro;
- janela lateral;
- câmera cinematográfica automática.

A câmera automática pode alternar lentamente entre enquadramentos.

O jogador deve poder desabilitar qualquer câmera que não gostar.

---

# 8. Progresso offline

O carro NÃO deve continuar indefinidamente enquanto o jogador está offline.

O jogador não pode perder grandes partes da viagem simplesmente porque fechou o jogo.

Pode existir progresso offline limitado.

Exemplo configurável:

- desligado;
- 30 minutos;
- 1 hora;
- 2 horas.

Depois desse período, o veículo estaciona automaticamente.

Eventos importantes nunca devem ser ultrapassados automaticamente.

Em single-player, não é necessário investir esforço significativo em impedir manipulação do relógio do computador.

---

# 9. Exploração

O jogador pode:

- estacionar;
- sair do carro;
- caminhar;
- explorar estruturas;
- entrar em cidades;
- visitar edifícios;
- coletar recursos;
- conversar com NPCs;
- realizar quests;
- procurar locais secretos;
- desmontar sucata;
- encontrar peças;
- descobrir histórias.

A exploração deve contrastar com a tranquilidade da estrada.

---

# 10. Pontos de interesse

Existem três categorias.

## Obrigatórios

Grandes locais pelos quais a estrada necessariamente passa.

Exemplos:

- grandes estações;
- cidades principais;
- checkpoints.

## Opcionais visíveis

O jogador consegue vê-los da estrada.

Exemplos:

- restaurante;
- motel;
- ferro-velho;
- posto;
- observatório;
- estrutura abandonada;
- mirante.

## Secretos

Não aparecem claramente no mapa.

Podem exigir:

- perceber uma placa;
- pegar determinada saída;
- ouvir rumor;
- seguir transmissão;
- possuir ferramenta;
- viajar em horário específico.

Exemplos:

- cidade perdida;
- estação abandonada;
- túnel;
- complexo subterrâneo;
- estrada antiga.

---

# 11. Cidades

As cidades devem funcionar como pequenos hubs no estilo Stardew Valley / Graveyard Keeper.

Cada cidade pode possuir:

- NPCs;
- comércio;
- crafting;
- oficina;
- quests;
- reputação;
- histórias;
- problemas locais;
- locais bloqueados;
- segredos.

As ações do jogador podem alterar permanentemente a cidade.

Exemplo:

um gerador quebrado mantém metade da cidade sem energia.

Após consertá-lo:

- iluminação retorna;
- lojas reabrem;
- NPCs aparecem;
- novas quests tornam-se disponíveis;
- aparência visual muda.

---

# 12. Sidequests

Sidequests são parte central do jogo.

Evitar estrutura exclusivamente:

“pegue 5 itens e receba dinheiro”.

Quests devem ajudar a construir histórias locais.

Podem envolver:

- reparar equipamento;
- procurar pessoa desaparecida;
- recuperar peça;
- investigar fenômeno;
- transportar objeto;
- ajudar comerciante;
- restaurar edifício;
- descobrir origem de problema;
- escolher entre moradores com interesses diferentes.

Resultado ideal:

o jogador sente que passou algum tempo vivendo naquele lugar antes de seguir viagem.

---

# 13. NPCs

NPCs importantes devem possuir:

- rotina;
- personalidade;
- pequenos arcos narrativos;
- relações com outros NPCs;
- diálogo variável;
- quests.

Alguns NPCs podem viajar.

O jogador pode encontrá-los novamente dezenas de milhares de quilômetros depois.

Exemplo:

encontra um mecânico no início.

Meses depois descobre que ele abriu uma oficina em outra região.

---

# 14. Crafting

Crafting é uma importante forma de progressão.

Categorias:

## Mecânica

- peças;
- tanques;
- pneus;
- suspensão;
- refrigeração;
- baterias.

## Eletrônica

- sensores;
- rádio;
- scanner;
- computador;
- navegação.

## Ferramentas

- chave;
- soldador;
- cortador;
- scanner;
- ferramentas de desmontagem.

## Traje

- oxigênio;
- proteção térmica;
- proteção contra radiação;
- mochila;
- botas magnéticas;
- iluminação;
- jetpack.

---

# 15. Recursos

Materiais básicos:

- sucata;
- aço;
- alumínio;
- cobre;
- plástico;
- borracha;
- fios.

Materiais tecnológicos:

- circuitos;
- chips;
- sensores;
- células de energia;
- motores.

Materiais avançados:

- ligas especiais;
- compostos;
- materiais espaciais;
- fragmentos raros.

---

# 16. Carro

No MVP, utilizar inicialmente apenas um carro altamente customizável.

Isso reduz drasticamente a produção de assets.

O carro deve desenvolver personalidade durante a viagem.

O jogador modifica:

- motor;
- tanque;
- pneus;
- suspensão;
- bateria;
- armazenamento;
- pintura;
- iluminação;
- interior;
- eletrônica.

Visualmente, o carro deve acumular história:

- adesivos;
- arranhões;
- sujeira;
- modificações;
- peças improvisadas;
- acessórios.

No futuro poderão existir diferentes veículos.

---

# 17. Relação velocidade x recursos

Mais velocidade deve possuir custo.

Exemplo:

100 km/h:
baixo consumo e desgaste.

160 km/h:
consumo e desgaste maiores.

220 km/h:
muito mais consumo e maior risco de problemas.

Isso cria escolhas.

Velocidade deixa de ser simplesmente “upgrade = melhor”.

---

# 18. Traje espacial

O traje também evolui.

Inicialmente possui pouca importância.

Quanto mais distante da Terra, mais necessário.

Progressão possível:

- capacidade de oxigênio;
- isolamento;
- resistência térmica;
- radiação;
- iluminação;
- scanner;
- mochila;
- botas magnéticas;
- propulsão.

Upgrades permitem explorar lugares anteriormente inacessíveis.

---

# 19. Rádio

O rádio é parte importante da atmosfera e também do sistema narrativo.

Pode possuir estações como:

- synthwave;
- chillwave;
- ambient;
- rock retrô;
- talk radio;
- notícias fictícias.

O rádio pode fornecer:

- rumores;
- informações;
- avisos;
- histórias;
- transmissões misteriosas.

Exemplo:

“Viajantes próximos ao km 104 mil relatam luzes estranhas perto da saída 731.”

Nenhum marcador obrigatório aparece.

O jogador decide investigar.

---

# 20. Fotografia e diário

Deve existir modo fotografia.

O jogo pode registrar:

- quilometragem;
- data;
- região;
- fotos;
- descobertas.

Ao final da viagem, o jogador possui um diário visual da campanha.

Isso ajuda a criar apego à jornada.

---

# 21. Progressão visual da viagem

O cenário deve mudar lentamente ao longo de milhares de quilômetros.

Não fazer transições abruptas.

Possível divisão:

## Região 1 — Endless Summer

Terra, montanhas, palmeiras, pôr do sol e estética retrofuturista.

## Região 2 — Cloudline

Estrada acima das nuvens.

## Região 3 — Orbital Blue

Atmosfera desaparecendo, Terra visível atrás.

## Região 4 — Deep Violet

Espaço, estruturas e estética cósmica.

## Região 5 — The Long Night

Escuridão, isolamento e poucos pontos de parada.

## Região 6 — Moonrise

Lua crescendo lentamente no horizonte ao longo de dias.

## Região 7 — Lunar Descent

Aproximação e chegada à Lua.

---

# 22. Direção artística

Retrofuturismo / retrowave.

Evitar estética genérica de neon rosa e azul em todo lugar.

Utilizar também:

- laranja;
- vermelho;
- amarelo;
- azul profundo;
- preto;
- iluminação branca;
- arquitetura brutalista;
- tecnologia analógica;
- CRTs;
- placas antigas;
- motéis;
- diners;
- postos de estrada;
- estruturas gigantes.

O mundo pode começar mais terrestre e se tornar progressivamente mais surreal.

---

# 23. Som

Áudio é fundamental.

Elementos:

- motor;
- pneus;
- vento;
- chuva;
- rádio;
- sons ambientais;
- silêncio.

Trechos do jogo devem utilizar pouco ou nenhum som musical.

O silêncio ajuda a comunicar distância e isolamento.

---

# 24. Online

Não implementar multiplayer tradicional no MVP.

O jogo deve funcionar completamente offline.

Isso reduz:

- servidores;
- custos;
- manutenção;
- bugs;
- complexidade.

Recursos online opcionais poderão ser adicionados futuramente.

Exemplos:

- Steam achievements;
- Steam Cloud;
- estatísticas;
- mensagens assíncronas;
- fantasmas de outros jogadores.

A arquitetura do core gameplay não deve depender de servidores.

---

# 25. MVP

O primeiro objetivo NÃO é construir todo o jogo.

É validar a experiência fundamental.

## MVP 0 — protótipo da estrada

Criar:

- carro dirigível;
- estrada;
- cenário;
- ciclo de carregamento de chunks;
- câmera;
- cruise control;
- Modo Viagem;
- contador de quilômetros.

Pergunta:

“É agradável deixar este jogo rodando durante 30 minutos?”

Se a resposta for não, não construir os outros sistemas ainda.

## MVP 1 — primeira parada

Adicionar:

- posto;
- personagem;
- diálogo;
- inventário;
- combustível;
- interação;
- saída e entrada no carro.

## MVP 2 — exploração

Adicionar:

- pequena área explorável;
- coleta;
- recursos;
- porta/objeto interativo;
- primeira sidequest.

## MVP 3 — crafting

Adicionar:

- bancada;
- receitas;
- materiais;
- primeiro upgrade do carro.

## MVP 4 — cidade

Criar uma pequena cidade completa.

Talvez Sunset Station.

5–8 NPCs.

Algumas quests.

Oficina.

Loja.

Mudança permanente decorrente de uma quest.

## MVP 5 — viagem persistente

Adicionar:

- save;
- quilometragem global;
- tempo;
- progressão offline limitada;
- regiões.

Depois disso avaliar expansão.

---

# 26. Prioridades de desenvolvimento

Ordem de importância:

1. sensação de viagem;
2. direção artística;
3. estrada procedural;
4. Modo Viagem;
5. exploração;
6. save/persistência;
7. NPCs;
8. quests;
9. crafting;
10. progressão;
11. conteúdo adicional;
12. recursos online.

Não desenvolver sistemas complexos antes da experiência principal funcionar.

---

# 27. Regras de design

1. Não transformar o jogo em simulador realista de carros.

2. Não transformar o jogo em survival extremamente punitivo.

3. Não colocar evento a cada minuto.

4. Não usar fast travel tradicional para substituir a viagem.

5. Não fazer o jogo continuar dezenas de milhares de quilômetros offline.

6. Não colocar marcadores para todos os segredos.

7. Não transformar crafting em grind excessivo.

8. Não construir sistemas online que sejam desnecessários.

9. Priorizar atmosfera sobre quantidade de mecânicas.

10. Sempre preservar a sensação de que o jogador está fazendo uma longa viagem física até a Lua.

---

# 28. Visão resumida

O jogador entra no carro.

Liga o rádio.

Seleciona uma velocidade.

Ativa o Modo Viagem.

Deixa o jogo aberto enquanto faz outra coisa.

No segundo monitor, uma estrada retrofuturista atravessa montanhas sob um pôr do sol.

Depois de algum tempo, ele percebe uma construção estranha.

Assume o controle.

Encontra uma saída.

Descobre uma pequena cidade que não estava no mapa.

Passa algum tempo conhecendo os moradores.

Ajuda a restaurar um gerador.

Explora uma estação abandonada.

Encontra materiais.

Constrói um upgrade para o carro.

Volta para a estrada.

Liga novamente o rádio.

No painel:

Distância percorrida: 92.418 km.

Destino: Lua.

291.982 km restantes.

E a viagem continua.
