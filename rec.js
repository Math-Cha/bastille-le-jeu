// BASTILLE — vidéo des 20 dernières secondes de la partie
// Recopie le canvas du jeu dans un canvas vidéo avec bandeaux (logo, score, adresse du site),
// enregistre en continu avec deux enregistreurs décalés de 10 s, et garde le plus long à la fin.
(function(){
  const OUT_W=540,OUT_H=960,FPS=30,SEG=20000,STAG=10000;
  const MIME=['video/mp4;codecs=avc1.42E01E','video/mp4;codecs=avc1','video/mp4','video/webm;codecs=vp9','video/webm;codecs=vp8','video/webm']
    .find(t=>window.MediaRecorder&&MediaRecorder.isTypeSupported&&MediaRecorder.isTypeSupported(t))||'';
  const supported=!!(MIME&&HTMLCanvasElement.prototype.captureStream);
  let cv,g,stream,raf=0,recs=[],timers=[],on=false,endCard=null,lastBlob=null;
  const site=()=>(location.host+location.pathname).replace(/index\.html$/,'').replace(/\/$/,'');
  const txt=id=>{const e=document.getElementById(id);return e?e.textContent.trim():''};

  function frame(){
    raf=requestAnimationFrame(frame);
    const src=document.getElementById('c');if(!src||!g)return;
    g.fillStyle='#1d1230';g.fillRect(0,0,OUT_W,OUT_H);
    // jeu au centre, entre les bandeaux
    const top=86,bot=74,h=OUT_H-top-bot,w=Math.min(OUT_W,h*src.width/src.height);
    const s3=document.getElementById('c3');if(s3&&s3.style.display!=='none')try{g.drawImage(s3,(OUT_W-w)/2,top,w,h)}catch(e){}
    try{g.drawImage(src,(OUT_W-w)/2,top,w,h)}catch(e){}
    // bandeau haut
    g.fillStyle='#1d1230';g.fillRect(0,0,OUT_W,top);
    g.fillStyle='#ffb830';g.font='900 38px Unbounded, system-ui, sans-serif';g.textBaseline='middle';g.textAlign='left';g.fillText('BASTILLE',22,top/2+2);
    g.textAlign='right';g.fillStyle='#fbf3e4';g.font='700 15px Figtree, system-ui, sans-serif';g.fillText('SCORE',OUT_W-22,top/2-16);
    g.font='800 26px Unbounded, system-ui, sans-serif';g.fillText(txt('score')||'0',OUT_W-22,top/2+12);
    // bandeau bas
    g.fillStyle='#ff5a4e';g.fillRect(0,OUT_H-bot,OUT_W,bot);
    g.fillStyle='#fbf3e4';g.textAlign='center';g.font='800 22px Unbounded, system-ui, sans-serif';g.fillText('À TOI DE JOUER',OUT_W/2,OUT_H-bot+26);
    g.font='700 17px Figtree, system-ui, sans-serif';g.fillText(site(),OUT_W/2,OUT_H-bot+53);
    if(endCard){
      g.fillStyle='rgba(29,18,48,.82)';g.fillRect(0,top,OUT_W,h);
      g.fillStyle='#fbf3e4';g.font='900 46px Unbounded, system-ui, sans-serif';g.fillText(endCard.title,OUT_W/2,OUT_H/2-70);
      g.fillStyle='#ffb830';g.font='800 40px Unbounded, system-ui, sans-serif';g.fillText(endCard.score,OUT_W/2,OUT_H/2);
      g.fillStyle='#fbf3e4';g.font='700 22px Figtree, system-ui, sans-serif';g.fillText(endCard.sub,OUT_W/2,OUT_H/2+56);
    }
  }
  function newRec(){
    const r={chunks:[],t0:performance.now(),mr:null};
    try{r.mr=new MediaRecorder(stream,{mimeType:MIME,videoBitsPerSecond:2500000})}catch(e){return null}
    r.mr.ondataavailable=e=>{if(e.data&&e.data.size)r.chunks.push(e.data)};
    r.mr.start(1000);return r;
  }
  function cycle(i){ // relance l'enregistreur i toutes les 20 s
    if(!on)return;
    const old=recs[i];recs[i]=newRec();
    if(old&&old.mr&&old.mr.state!=='inactive'){try{old.mr.stop()}catch(e){}}
    timers[i]=setTimeout(()=>cycle(i),SEG);
  }
  function start(){
    if(!supported||on)return;
    if(!cv){cv=document.createElement('canvas');cv.width=OUT_W;cv.height=OUT_H;g=cv.getContext('2d');stream=cv.captureStream(FPS)}
    on=true;endCard=null;lastBlob=null;recs=[null,null];
    cancelAnimationFrame(raf);frame();
    cycle(0);timers[1]=setTimeout(()=>cycle(1),STAG);
  }
  function stop(card){
    return new Promise(res=>{
      if(!on){res(lastBlob);return}
      endCard=card||null;
      setTimeout(()=>{ // 1,5 s d'écran de fin incrusté
        on=false;timers.forEach(clearTimeout);
        const live=recs.filter(r=>r&&r.mr&&r.mr.state!=='inactive').sort((a,b)=>a.t0-b.t0);
        const best=live[0];
        recs.forEach(r=>{if(r&&r!==best&&r.mr&&r.mr.state!=='inactive'){try{r.mr.stop()}catch(e){}}});
        if(!best){cancelAnimationFrame(raf);res(null);return}
        best.mr.onstop=()=>{cancelAnimationFrame(raf);lastBlob=new Blob(best.chunks,{type:MIME.split(';')[0]});res(lastBlob)};
        try{best.mr.stop()}catch(e){cancelAnimationFrame(raf);res(null)}
      },endCard?1500:0);
    });
  }
  window.__btRec={supported,start,stop,ext:()=>MIME.indexOf('mp4')>=0?'mp4':'webm',mime:()=>MIME.split(';')[0],last:()=>lastBlob};
})();
