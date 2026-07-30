# RotoDaBruxos

Rotoscopia assistida por IA para foto e vídeo, executada localmente no navegador com Segment Anything 2, WebGPU e FFmpeg.wasm.

## Recursos

- foto: carregue, clique no objeto e exporte a máscara composta em PNG;
- vídeo: escolha um quadro, gere a máscara e exporte a composição em MP4;
- modelos SAM2 Tiny, Small e Base+ em ONNX;
- aceleração WebGPU via ONNX Runtime Web;
- modelos armazenados no cache privado do navegador após o primeiro download;
- arquivos do usuário não são enviados para o servidor da aplicação;
- interface responsiva e pronta para GitHub Pages.

> Na versão atual, a exportação de vídeo aplica ao clipe a máscara criada no quadro escolhido. Rastreamento temporal quadro a quadro é uma evolução planejada.

## Rodar localmente

Requer Node.js 20 ou mais recente.

```bash
npm install
npm run dev
```

Abra o endereço HTTPS/local informado pelo terminal usando Chrome ou Edge atualizado. WebGPU e o armazenamento privado do navegador exigem uma origem segura; `localhost` é aceito.

Para testar a versão de produção:

```bash
npm run build
npm run start
```

No Windows, depois de instalar as dependências e gerar o build, você também pode
dar dois cliques em `iniciar-local.bat`.

Não abra `public/index.html` diretamente. Endereços `file:///` têm origem nula e
o navegador bloqueia o Web Worker necessário para executar o FFmpeg.

## Publicar no GitHub Pages

1. Crie um repositório novo no GitHub.
2. Envie o conteúdo desta pasta para a raiz do repositório.
3. Execute `npm run build` antes de enviar, para atualizar a pasta `build`.
4. Em **Settings → Pages**, escolha **Deploy from a branch**.
5. Selecione a branch `main`, a pasta `/(root)` e clique em **Save**.

O GitHub Pages encontra `index.html` diretamente na raiz. A pasta `public` contém
apenas arquivos-fonte auxiliares; ela não é a pasta configurada para publicação.

O primeiro uso baixa o modelo escolhido. Os encoders maiores podem ultrapassar 100 MB e por isso ficam hospedados externamente, como no projeto técnico de referência.

## Compatibilidade

- recomendado: Chrome ou Edge recente, com aceleração de hardware;
- WebGPU precisa estar disponível;
- dispositivos móveis e GPUs com pouca memória devem usar o modelo Tiny;
- FFmpeg.wasm pode consumir bastante memória durante vídeos longos. Comece com clipes curtos.

## Créditos

Baseado no trabalho aberto de [Lucas Gelfond / webgpu-sam2](https://github.com/lucasgelfond/webgpu-sam2), no [Segment Anything 2](https://github.com/facebookresearch/sam2) da Meta e nas ideias de processamento em tempo real de [Gy920/segment-anything-2-real-time](https://github.com/Gy920/segment-anything-2-real-time).

Consulte as licenças e avisos dos projetos e modelos originais antes de redistribuir ou usar comercialmente.
