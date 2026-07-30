<script lang="ts">
  import { get } from 'svelte/store';
  // @ts-ignore — WebGPU is shipped as an experimental ONNX Runtime subpath.
  import * as ORT from 'onnxruntime-web/webgpu';
  import { FFmpeg } from '@ffmpeg/ffmpeg';
  import { fetchFile, toBlobURL } from '@ffmpeg/util';
  import { currentStatus, encoderOutput, fetchModel, inputImageData, modelSize } from './lib';
  import { processImage } from './components/encoder/utils';
  import { prepareDecodingInputs, scaleAndProcessMasks } from './components/decoder/utils';

  // WebGPU still uses ORT's JSEP WebAssembly bootstrap. Loading the matching
  // runtime files from a fixed HTTPS URL avoids broken relative paths on
  // GitHub Pages project subdirectories.
  ORT.env.wasm.wasmPaths = 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.27.0/dist/';
  ORT.env.wasm.numThreads = 1;
  ORT.env.wasm.proxy = false;
  ORT.env.webgpu.powerPreference = 'high-performance';

  let fileInput: HTMLInputElement;
  let mediaImage: HTMLImageElement;
  let mediaVideo: HTMLVideoElement;
  let canvas: HTMLCanvasElement;
  let activeTab: 'image' | 'video' = 'image';
  let file: File | null = null;
  let objectUrl = '';
  let isVideo = false;
  let busy = false;
  let ready = false;
  let hasMask = false;
  let message = 'Envie uma foto ou um vídeo para começar.';
  let progress = 0;
  let threshold = 0.15;
  let opacity = 58;
  let point: { x: number; y: number } | null = null;
  let ffmpeg: FFmpeg | null = null;
  let lastMask: Float32Array | null = null;

  const color = [148, 211, 54] as [number, number, number];

  function choose(type: 'image' | 'video') {
    activeTab = type;
    fileInput.accept = type === 'image' ? 'image/png,image/jpeg,image/webp' : 'video/mp4,video/webm,video/quicktime';
    fileInput.click();
  }

  function reset() {
    if (objectUrl) URL.revokeObjectURL(objectUrl);
    file = null; objectUrl = ''; ready = false; hasMask = false; point = null; lastMask = null; progress = 0;
    message = 'Envie uma foto ou um vídeo para começar.';
    if (canvas) canvas.getContext('2d')?.clearRect(0, 0, canvas.width, canvas.height);
  }

  async function loadFile(selected: File) {
    reset();
    file = selected;
    isVideo = selected.type.startsWith('video/');
    activeTab = isVideo ? 'video' : 'image';
    objectUrl = URL.createObjectURL(selected);
    message = isVideo ? 'Vídeo carregado. Escolha um quadro e clique em “Preparar quadro”.' : 'Preparando imagem para o SAM2…';
    await new Promise((resolve) => setTimeout(resolve));
    if (!isVideo) {
      mediaImage.onload = () => prepare(mediaImage);
      mediaImage.src = objectUrl;
    }
  }

  async function frameAsImage() {
    const c = document.createElement('canvas');
    c.width = mediaVideo.videoWidth; c.height = mediaVideo.videoHeight;
    c.getContext('2d')?.drawImage(mediaVideo, 0, 0);
    const img = new Image();
    img.src = c.toDataURL('image/jpeg', .94);
    await img.decode();
    await prepare(img);
  }

  async function prepare(img: HTMLImageElement) {
    if (!navigator.gpu) {
      message = 'WebGPU não está disponível. Use Chrome ou Edge atualizado com aceleração de hardware.';
      return;
    }
    busy = true; ready = false; hasMask = false; progress = 12;
    message = 'Baixando ou abrindo o encoder SAM2… o primeiro uso pode demorar.';
    try {
      await processImage(img, $modelSize);
      progress = 72;
      drawBase();
      ready = true;
      message = 'Embedding pronto. Clique no objeto que deseja recortar.';
    } catch (e) {
      message = `Não foi possível preparar o SAM2: ${e}`;
    } finally { busy = false; }
  }

  function drawBase() {
    const data = get(inputImageData);
    if (!data || !canvas) return;
    canvas.width = 1024; canvas.height = 1024;
    canvas.getContext('2d')?.putImageData(data, 0, 0);
  }

  async function segment(event: MouseEvent) {
    if (!ready || busy) return;
    const rect = canvas.getBoundingClientRect();
    point = {
      x: Math.max(0, Math.min(1024, (event.clientX - rect.left) * 1024 / rect.width)),
      y: Math.max(0, Math.min(1024, (event.clientY - rect.top) * 1024 / rect.height))
    };
    busy = true; progress = 78; message = 'Gerando a máscara no WebGPU…';
    try {
      const decoder = await fetchModel({ isEncoder: false, modelSize: $modelSize });
      const session = await ORT.InferenceSession.create(decoder, {
        executionProviders: ['webgpu'],
        graphOptimizationLevel: 'disabled'
      });
      const coords = new ORT.Tensor(new Float32Array([point.x, point.y, 0, 0]), [1, 2, 2]);
      const labels = new ORT.Tensor(new Float32Array([1, -1]), [1, 2]);
      const result = await session.run(prepareDecodingInputs(get(encoderOutput), coords, labels));
      const masks = scaleAndProcessMasks(result.masks, threshold);
      lastMask = masks[0];
      drawBase();
      paintMask(lastMask);
      hasMask = true; progress = 100; message = 'Máscara pronta. Clique em outro ponto para refazer ou exporte o resultado.';
    } catch (e) {
      console.error(e);
      message = 'O WebGPU não conseguiu abrir o decodificador. Recarregue a página e tente o modelo Tiny; feche outras abas que usam a GPU.';
    } finally { busy = false; }
  }

  function paintMask(mask: Float32Array) {
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    const image = ctx.getImageData(0, 0, 1024, 1024);
    for (let i = 0; i < mask.length; i++) if (mask[i]) {
      const p = i * 4;
      image.data[p] = image.data[p] * (1 - opacity / 100) + color[0] * opacity / 100;
      image.data[p + 1] = image.data[p + 1] * (1 - opacity / 100) + color[1] * opacity / 100;
      image.data[p + 2] = image.data[p + 2] * (1 - opacity / 100) + color[2] * opacity / 100;
    }
    ctx.putImageData(image, 0, 0);
  }

  function downloadCanvas() {
    canvas.toBlob((blob) => blob && download(blob, `RotoDaBruxos-${Date.now()}.png`), 'image/png');
  }

  function download(blob: Blob, name: string) {
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  async function transparentMaskBlob() {
    const c = document.createElement('canvas'); c.width = 1024; c.height = 1024;
    const ctx = c.getContext('2d')!; const image = ctx.createImageData(1024, 1024);
    if (lastMask) for (let i = 0; i < lastMask.length; i++) if (lastMask[i]) {
      const p = i * 4; image.data[p] = color[0]; image.data[p + 1] = color[1];
      image.data[p + 2] = color[2]; image.data[p + 3] = Math.round(opacity * 2.55);
    }
    ctx.putImageData(image, 0, 0);
    return new Promise<Blob>((resolve) => c.toBlob((b) => resolve(b!), 'image/png'));
  }

  async function exportVideo() {
    if (!file || !isVideo || !hasMask) return;
    if (location.protocol === 'file:') {
      message = 'O FFmpeg não pode iniciar em file://. Feche esta página e execute iniciar-local.bat; depois abra http://localhost:8080.';
      return;
    }
    busy = true; message = 'Carregando FFmpeg e renderizando o vídeo localmente…'; progress = 10;
    try {
      ffmpeg ||= new FFmpeg();
      if (!ffmpeg.loaded) {
        const base = 'https://cdn.jsdelivr.net/npm/@ffmpeg/core@0.12.10/dist/esm';
        await ffmpeg.load({
          coreURL: await toBlobURL(`${base}/ffmpeg-core.js`, 'text/javascript'),
          wasmURL: await toBlobURL(`${base}/ffmpeg-core.wasm`, 'application/wasm')
        });
      }
      ffmpeg.on('progress', ({ progress: p }) => { progress = Math.max(10, Math.round(p * 100)); });
      const inputName = file.type.includes('webm') ? 'input.webm' : 'input.mp4';
      await ffmpeg.writeFile(inputName, await fetchFile(file));
      const maskBlob = await transparentMaskBlob();
      await ffmpeg.writeFile('mask.png', await fetchFile(maskBlob));
      await ffmpeg.exec(['-i', inputName, '-loop', '1', '-i', 'mask.png', '-filter_complex',
        '[1:v]format=rgba[fg];[0:v][fg]overlay=(W-w)/2:(H-h)/2:shortest=1',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', 'resultado.mp4']);
      const data = await ffmpeg.readFile('resultado.mp4');
      download(new Blob([data as Uint8Array], { type: 'video/mp4' }), `RotoDaBruxos-${Date.now()}.mp4`);
      progress = 100; message = 'Vídeo exportado com FFmpeg.';
    } catch (e) {
      message = `Não foi possível exportar o vídeo: ${e}`;
    } finally { busy = false; }
  }

  function handleDrop(event: DragEvent) {
    event.preventDefault();
    const selected = event.dataTransfer?.files?.[0];
    if (selected) loadFile(selected);
  }
</script>

<svelte:head>
  <title>RotoDaBruxos — Segment Anything em WebGPU</title>
  <meta name="description" content="Recorte objetos em fotos e vídeos com SAM2, WebGPU e FFmpeg, direto no navegador." />
</svelte:head>

<aside class="rail">
  <img src="./Bruxos.png" alt="Bruxos" />
  <nav aria-label="Navegação"><a class="active" href="#studio">⌂</a><a href="#como">?</a></nav>
  <a class="repo" href="https://github.com/lucasgelfond/webgpu-sam2" target="_blank" rel="noreferrer">GH</a>
</aside>

<main>
  <header>
    <a class="wordmark" href="#studio"><img src="./Bruxos.png" alt="" /><span>Roto<strong>DaBruxos</strong></span></a>
    <div class:online={!!navigator.gpu} class="runtime"><i></i>{navigator.gpu ? 'WEBGPU ATIVA' : 'WEBGPU INDISPONÍVEL'}</div>
  </header>

  <section class="hero">
    <div>
      <span class="eyebrow">SEGMENT ANYTHING 2 · 100% NO NAVEGADOR</span>
      <h1>Recorte qualquer coisa.<br /><em>Frame por frame.</em></h1>
      <p>Rotoscopia assistida por IA para fotos e vídeos. Escolha um objeto com um clique, refine a máscara e exporte sem enviar seus arquivos para nenhum servidor.</p>
      <div class="chips"><span>✦ SAM2</span><span>◈ WEBGPU</span><span>▶ FFMPEG</span></div>
    </div>
    <div class="orb" aria-hidden="true"><span></span><img src="./Bruxos.png" alt="" /></div>
  </section>

  <section id="studio" class="studio">
    <div class="section-title"><span>01</span><div><small>ESTÚDIO DE RECORTE</small><h2>Selecione. Segmente. Exporte.</h2></div></div>
    <div class="workspace">
      <section class="viewer">
        <div class="viewer-bar"><span>{file ? file.name : 'NENHUM ARQUIVO'}</span><b>{isVideo ? 'VÍDEO' : 'IMAGEM'}</b></div>
        {#if !file}
          <button class="drop" on:click={() => choose(activeTab)} on:drop={handleDrop} on:dragover={(e) => e.preventDefault()}>
            <span>＋</span><strong>Arraste seu arquivo aqui</strong><small>ou clique para selecionar</small>
          </button>
        {:else}
          <div class="stage">
            {#if isVideo}
              <!-- svelte-ignore a11y-media-has-caption -->
              <video bind:this={mediaVideo} src={objectUrl} controls playsinline></video>
            {:else}
              <img bind:this={mediaImage} alt="Mídia selecionada" />
            {/if}
            <canvas class:visible={ready} bind:this={canvas} on:click={segment}></canvas>
            {#if point}<i class="pin" style={`left:${point.x / 10.24}%;top:${point.y / 10.24}%`}></i>{/if}
          </div>
        {/if}
      </section>

      <aside class="controls">
        <div class="tabs">
          <button class:active={activeTab === 'image'} on:click={() => choose('image')}>▧ FOTO</button>
          <button class:active={activeTab === 'video'} on:click={() => choose('video')}>▶ VÍDEO</button>
          <input bind:this={fileInput} type="file" hidden on:change={(e) => (e.currentTarget.files?.[0] && loadFile(e.currentTarget.files[0]))} />
        </div>
        <div class="status"><span class:done={ready}>{ready ? '✓' : '01'}</span><div><strong>Preparar mídia</strong><small>{message}</small></div></div>
        {#if isVideo && file}<button class="action secondary" disabled={busy} on:click={frameAsImage}>Capturar quadro atual <b>→</b></button>{/if}
        <label>MODELO
          <select bind:value={$modelSize} disabled={busy || ready}><option value="tiny">SAM2 Tiny · mais rápido</option><option value="small">SAM2 Small · equilibrado</option><option value="base_plus">SAM2 Base+ · mais preciso</option></select>
        </label>
        <label>LIMIAR DA MÁSCARA <output>{threshold.toFixed(2)}</output><input type="range" min="0" max=".8" step=".05" bind:value={threshold} /></label>
        <label>OPACIDADE <output>{opacity}%</output><input type="range" min="20" max="90" bind:value={opacity} /></label>
        <div class="progress"><i style={`width:${progress}%`}></i></div>
        {#if hasMask}
          {#if isVideo}<button class="action" disabled={busy} on:click={exportVideo}>Exportar vídeo · MP4 <b>↓</b></button>
          {:else}<button class="action" on:click={downloadCanvas}>Baixar recorte · PNG <b>↓</b></button>{/if}
        {/if}
        {#if file}<button class="clear" on:click={reset}>Remover arquivo</button>{/if}
        <p class="privacy">● PROCESSAMENTO LOCAL<br />Seus arquivos nunca saem deste dispositivo.</p>
      </aside>
    </div>
  </section>

  <section id="como" class="how">
    <div class="section-title"><span>02</span><div><small>COMO FUNCIONA</small><h2>Magia em três passos.</h2></div></div>
    <div class="steps"><article><b>01</b><h3>Carregue</h3><p>Foto ou vídeo direto do seu dispositivo.</p></article><article><b>02</b><h3>Aponte</h3><p>Clique no objeto e o SAM2 cria a máscara.</p></article><article><b>03</b><h3>Exporte</h3><p>PNG para imagens ou MP4 processado pelo FFmpeg.</p></article></div>
  </section>

  <footer><img src="./Bruxos.png" alt="" /><span>ROTODABRUXOS / 2026</span><span>FEITO COM MAGIA E PIXELS</span></footer>
</main>
