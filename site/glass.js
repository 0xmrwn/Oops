// The page's glass. A WebGL lens over the draft: the page paints the words
// under the glass into a texture, and the shader bends them through capsules
// with a rounded bezel (Snell's law, a touch of dispersion, a lit rim).
// Each capsule follows a DOM element, so CSS still owns the motion.

const FRAG = `precision highp float;
uniform sampler2D u_tex;
uniform vec2 u_res, u_light;
uniform vec4 u_shape[6]; // centre and half size of each piece, in device px
uniform float u_fade[6];
uniform float u_dpr, u_bezel, u_melt, u_dark, u_frost;
const float IOR = 1.5, DISP = 0.035, MAG = 1.04;

// A rounded box whose corners are as round as it allows: a capsule either way up.
float piece(vec2 p, vec4 s) {
  float r = min(s.z, s.w);
  vec2 q = abs(p - s.xy) - (s.zw - r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Pieces closer than u_melt flow into each other.
float surface(vec2 p) {
  float d = 1e5;
  for (int i = 0; i < 6; i++) {
    if (u_shape[i].z < 0.5) continue;
    float e = piece(p, u_shape[i]);
    float h = max(u_melt - abs(d - e), 0.0) / u_melt;
    d = min(d, e) - h * h * u_melt * 0.25;
  }
  return d;
}

vec3 bent(vec2 base, vec2 n, vec3 off) {
  vec2 inv = 1.0 / u_res;
  return vec3(texture2D(u_tex, (base - n * off.r) * inv).r,
              texture2D(u_tex, (base - n * off.g) * inv).g,
              texture2D(u_tex, (base - n * off.b) * inv).b);
}

void main() {
  vec2 f = gl_FragCoord.xy;
  float sd = surface(f);
  if (sd > 40.0 * u_dpr) { gl_FragColor = vec4(0.0); return; }

  // The piece this pixel belongs to gives it its centre and its opacity.
  vec2 centre = f;
  float fade = 0.0, near = 1e5;
  for (int i = 0; i < 6; i++) {
    if (u_shape[i].z < 0.5) continue;
    float e = piece(f, u_shape[i]);
    if (e < near) { near = e; centre = u_shape[i].xy; fade = u_fade[i]; }
  }

  // A soft shadow outside the glass only, lighter on a light page.
  float sds = max(surface(f + vec2(0.0, 2.0 * u_dpr)), 0.0);
  float shadow = mix(0.07, 0.22, u_dark) * exp(-sds / (9.0 * u_dpr))
               + mix(0.05, 0.12, u_dark) * exp(-sds / (1.2 * u_dpr));
  float cover = clamp(0.5 - sd, 0.0, 1.0);
  if (cover <= 0.0) { gl_FragColor = vec4(0.0, 0.0, 0.0, shadow * fade); return; }

  vec2 e = vec2(u_dpr, 0.0);
  vec2 g = vec2(surface(f + e.xy) - surface(f - e.xy), surface(f + e.yx) - surface(f - e.yx));
  vec2 n = length(g) > 1e-5 ? normalize(g) : vec2(0.0);

  // Convex squircle bezel; flat, clear glass inside it.
  float x = clamp(-sd / u_bezel, 0.0, 1.0);
  float k = 1.0 - x;
  float s4 = max(1.0 - k * k * k * k, 1e-4);
  float h = u_bezel * pow(s4, 0.25);
  float ti = atan(k * k * k * pow(s4, -0.75));
  vec3 off = h * tan(ti - asin(sin(ti) / vec3(IOR - DISP, IOR, IOR + DISP)));

  vec2 base = centre + (f - centre) / MAG;
  vec3 col = bent(base, n, off);
  if (u_frost > 0.5) {
    // Regular glass: what lies behind is blurred and veiled.
    for (int i = 0; i < 8; i++) {
      float a = float(i) * 0.7854;
      col += bent(base + vec2(cos(a), sin(a)) * 5.0 * u_dpr, n, off);
    }
    col = mix(col / 9.0, mix(vec3(1.0), vec3(0.2), u_dark), mix(0.45, 0.5, u_dark));
  }
  col *= mix(0.955, 0.985, u_dark); // dimming layer: headroom for the highlights

  float ndl = dot(n, u_light);
  float lit = pow(max(ndl, 0.0), 2.0) + 0.5 * pow(max(-ndl, 0.0), 2.0);
  float rim = -sd / u_dpr;

  col += k * k * smoothstep(0.1, 0.9, -n.y) * mix(0.08, 0.11, u_dark); // light pooling low
  col += k * k * smoothstep(0.1, 0.9, n.y) * mix(0.10, 0.14, u_dark);  // sheen up top

  float spec = clamp(smoothstep(1.6, 0.4, rim) * (0.25 + 0.75 * lit) + pow(sin(ti), 4.0) * k * k * lit * 0.45, 0.0, 1.0);
  col = mix(col, vec3(1.0), spec * mix(0.85, 0.7, u_dark));

  // A dark inner edge on the unlit side: the cue that survives on a light page.
  float band = smoothstep(0.6, 1.4, rim) * smoothstep(3.2, 1.8, rim);
  col *= 1.0 - band * (1.0 - lit) * mix(0.16, 0.10, u_dark);
  col = mix(col, vec3(u_dark), smoothstep(0.8, 0.0, rim) * mix(0.10, 0.18, u_dark) * (1.0 - spec));

  gl_FragColor = vec4(col * cover, cover + shadow * (1.0 - cover)) * fade;
}`;

const MARGIN = 28; // room for the shadow and the refraction offsets, in CSS px

function createGlass({ canvas, stage, draft, roots, frames }) {
  const gl = canvas.getContext("webgl", { premultipliedAlpha: true, antialias: false });
  if (!gl) return null;

  const compile = (type, source) => {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
    return shader;
  };
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl.VERTEX_SHADER, "attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}"));
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  gl.useProgram(program);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
  for (const key of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_2D, key, gl.LINEAR);
  for (const key of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T]) gl.texParameteri(gl.TEXTURE_2D, key, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  const U = {};
  for (const name of ["res", "light", "shape", "fade", "dpr", "bezel", "melt", "dark", "frost"]) {
    U[name] = gl.getUniformLocation(program, `u_${name}`);
  }

  const paper = document.createElement("canvas");
  const ink = paper.getContext("2d");
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const shapes = [];
  let dpr = 1, box = { x: 0, y: 0, w: 1, h: 1 }, running = false;

  // Covers everything the glass will travel over during one act.
  function fit(left, top, width, height) {
    dpr = Math.min(devicePixelRatio || 1, 2);
    box = { x: left - MARGIN, y: top - MARGIN, w: width + MARGIN * 2, h: height + MARGIN * 2 };
    Object.assign(canvas.style, { left: `${box.x}px`, top: `${box.y}px`, width: `${box.w}px`, height: `${box.h}px` });
    canvas.width = paper.width = Math.round(box.w * dpr);
    canvas.height = paper.height = Math.round(box.h * dpr);
  }

  // Repaints what lies under the canvas exactly where the page laid it out:
  // the highlights, each word at its own rect, and the caret.
  function paint(origin) {
    const style = getComputedStyle(draft);
    ink.setTransform(dpr, 0, 0, dpr, -(origin.left + box.x) * dpr, -(origin.top + box.y) * dpr);
    ink.globalAlpha = 1;
    ink.fillStyle = getComputedStyle(document.body).backgroundColor;
    ink.fillRect(origin.left + box.x, origin.top + box.y, box.w, box.h);

    // The field the draft sits in: its sheet and its outline.
    for (const frame of frames) {
      const look = getComputedStyle(frame), rect = frame.getBoundingClientRect();
      const line = parseFloat(look.borderTopWidth);
      ink.globalAlpha = 1;
      ink.fillStyle = look.backgroundColor;
      ink.strokeStyle = look.borderTopColor;
      ink.lineWidth = line;
      ink.beginPath();
      ink.roundRect(rect.left + line / 2, rect.top + line / 2, rect.width - line, rect.height - line, parseFloat(look.borderTopLeftRadius));
      ink.fill();
      ink.stroke();
    }

    for (const mark of draft.querySelectorAll("mark")) {
      const pill = getComputedStyle(mark, "::before");
      const rect = mark.getBoundingClientRect();
      const em = parseFloat(style.fontSize);
      ink.globalAlpha = parseFloat(pill.opacity) || 0;
      ink.fillStyle = pill.backgroundColor;
      ink.beginPath();
      ink.roundRect(rect.left - em * 0.07, rect.top + em * 0.08, rect.width + em * 0.14, rect.height - em * 0.1, em * 0.16);
      ink.fill();
    }

    ink.textBaseline = "alphabetic";
    const range = document.createRange();
    for (const root of roots) {
      const fade = parseFloat(getComputedStyle(root).opacity);
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let node; (node = walker.nextNode()); ) {
        const font = getComputedStyle(node.parentElement);
        ink.font = `${font.fontWeight} ${font.fontSize} ${font.fontFamily}`;
        if ("letterSpacing" in ink) ink.letterSpacing = font.letterSpacing;
        ink.fillStyle = font.color;
        ink.globalAlpha = fade * (node.parentElement === root ? 1 : parseFloat(font.opacity));
        const metrics = ink.measureText("Hg");
        const ascent = metrics.fontBoundingBoxAscent, descent = metrics.fontBoundingBoxDescent;
        for (const word of node.data.matchAll(/\S+/g)) {
          range.setStart(node, word.index);
          range.setEnd(node, word.index + word[0].length);
          const rect = range.getBoundingClientRect();
          if (rect.bottom < origin.top + box.y || rect.top > origin.top + box.y + box.h) continue;
          ink.fillText(word[0], rect.left, rect.top + (rect.height - ascent - descent) / 2 + ascent);
        }
      }
    }

    const caret = draft.querySelector(".caret");
    if (caret) {
      const rect = caret.getBoundingClientRect();
      const look = getComputedStyle(caret);
      ink.globalAlpha = parseFloat(look.opacity);
      ink.fillStyle = look.backgroundColor;
      ink.fillRect(rect.left, rect.top, rect.width, rect.height);
    }
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, paper);
  }

  function frame() {
    const live = shapes.filter(({ el }) => el.offsetWidth && (parseFloat(getComputedStyle(el).opacity) > 0.004 || el.classList.contains("is-in")));
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (!live.length) { running = false; return; }
    const origin = stage.getBoundingClientRect();
    paint(origin);
    gl.uniform2f(U.res, canvas.width, canvas.height);
    gl.uniform2f(U.light, -0.5, 0.866);
    gl.uniform1f(U.dpr, dpr);
    gl.uniform1f(U.dark, dark.matches ? 1 : 0);
    gl.uniform1f(U.bezel, 0.23 * live[0].el.offsetHeight * dpr);
    gl.uniform1f(U.melt, 0.2 * live[0].el.offsetHeight * dpr);
    // Clear pieces are drawn as one surface so they can flow into each other;
    // each frosted piece is a surface of its own.
    const clear = live.filter((shape) => !shape.frost);
    for (const group of [clear, ...live.filter((shape) => shape.frost).map((shape) => [shape])]) {
      if (!group.length) continue;
      const shape = new Float32Array(24), fade = new Float32Array(6);
      group.slice(0, 6).forEach(({ el }, i) => {
        const rect = el.getBoundingClientRect();
        shape[i * 4] = (rect.left + rect.width / 2 - origin.left - box.x) * dpr;
        shape[i * 4 + 1] = canvas.height - (rect.top + rect.height / 2 - origin.top - box.y) * dpr;
        shape[i * 4 + 2] = (rect.width / 2) * dpr;
        shape[i * 4 + 3] = (rect.height / 2) * dpr;
        fade[i] = parseFloat(getComputedStyle(el).opacity);
      });
      gl.uniform4fv(U.shape, shape);
      gl.uniform1fv(U.fade, fade);
      gl.uniform1f(U.frost, group[0].frost ? 1 : 0);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    requestAnimationFrame(frame);
  }

  return {
    fit,
    add(el, frost) { shapes.push({ el, frost }); },
    wake() {
      if (running) return;
      running = true;
      requestAnimationFrame(frame);
    },
  };
}
