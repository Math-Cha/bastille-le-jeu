// BASTILLE — statistiques, compte joueur (connexion par code e-mail), vidéo, e-mail de score, parrainage
(function(){
  const C=window.BT_CONFIG||{};
  const ok=!!(C.url&&C.key&&window.supabase);
  const sb=ok?window.supabase.createClient(C.url,C.key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;
  const LS={get(k){try{return localStorage.getItem(k)}catch(e){return null}},set(k,v){try{localStorage.setItem(k,v)}catch(e){}},del(k){try{localStorage.removeItem(k)}catch(e){}}};
  const uuid=()=>crypto.randomUUID?crypto.randomUUID():'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const r=Math.random()*16|0;return(c==='x'?r:(r&3|8)).toString(16)});
  let visitor=LS.get('bt_visitor');if(!visitor){visitor=uuid();LS.set('bt_visitor',visitor)}
  const device=/Mobi|Android|iPhone|iPad/i.test(navigator.userAgent)?'mobile':'desktop';
  const base=()=>location.origin+location.pathname.replace(/index\.html$/,'');
  const $=id=>document.getElementById(id);

  // parrainage : ?ref=CODE dans l'adresse
  try{const r=new URLSearchParams(location.search).get('ref');if(r&&/^[a-z0-9]{4,16}$/i.test(r))LS.set('bt_ref',r)}catch(e){}

  // visite (une fois par session de navigation)
  if(ok){try{if(!sessionStorage.getItem('bt_v')){sessionStorage.setItem('bt_v','1');let ref='';try{ref=document.referrer?new URL(document.referrer).hostname:''}catch(e){}
    sb.from('visits').insert({visitor,referrer:ref.slice(0,300)||null,device,ref:LS.get('bt_ref')}).then(()=>{})}}catch(e){}}

  let last=null; // dernière partie : {gkey, side, score, stage, ...}
  let clipBlob=null,clipP=null;

  async function user(){if(!sb)return null;const {data}=await sb.auth.getSession();return data.session?data.session.user:null}

  async function syncCredits(){
    const u=await user();if(!u)return;
    const {data}=await sb.from('profiles').select('credits_bonus,ref_code,pseudo').eq('id',u.id).maybeSingle();if(!data)return;
    LS.set('bt_refcode',data.ref_code);if(data.pseudo)LS.set('bt_pseudo',data.pseudo);
    const k='bt_claimed_'+u.id,done=+(LS.get(k)||0),delta=(data.credits_bonus||0)-done;
    if(delta>0&&window.__btAddCoins){window.__btAddCoins(delta);LS.set(k,String(data.credits_bonus));toast('PARRAINAGE : +'+delta+' PIÈCES')}
    renderAcct();
  }
  function toast(t){const d=document.createElement('div');d.textContent=t;d.style.cssText='position:fixed;left:50%;top:18px;transform:translateX(-50%);z-index:99;background:#2ee6b0;color:#1d1230;font:700 13px Figtree,system-ui,sans-serif;padding:9px 14px;border-radius:12px;box-shadow:3px 3px 0 #1d1230';document.body.appendChild(d);setTimeout(()=>d.remove(),3200)}

  // ---------- appelé par le jeu ----------
  function gameStart(){try{window.__btRec&&window.__btRec.start()}catch(e){}}
  function gameEnd(g){
    const gkey=uuid();
    last={gkey,side:g.side,score:Math.max(0,Math.round(g.score||0)),stage:Math.max(1,g.stage|0),sent:false,uploaded:null};
    if(sb){const row={gkey,visitor,side:g.side,score:last.score,stage:last.stage,bosses:Math.max(0,g.bosses|0),duration_s:Math.max(0,Math.min(86400,g.dur|0)),device,
      tenue:(g.tenue||'').slice(0,40)||null,arme:(g.arme||'').slice(0,40)||null,exo:(g.exo||'').slice(0,40)||null,picked:(g.picked||'').slice(0,300)||null,perks:(g.perks||'').slice(0,100)||null};
      last.won=!!g.won;last.time=g.won?Math.max(0,Math.min(86400,g.time|0)):null;
      const ext=Object.assign({},row,{won:last.won,time_s:last.time,era:(g.era||'').slice(0,12)||null});
      // les colonnes won/time_s/era arrivent avec la migration du 25/10 : sans elle, on enregistre la partie sans
      sb.from('games').insert(ext).then(({error})=>{if(error&&/won|time_s|era|column|schema/i.test(error.message||''))return sb.from('games').insert(row)}).then(()=>setTimeout(showMyRank,600))}
    // vidéo
    clipBlob=null;$('clipbox')&&($('clipbox').hidden=true);
    if(window.__btRec&&window.__btRec.supported){
      const card={title:g.title||'GAME OVER',score:g.scoreTxt||String(last.score),sub:(g.side==='bloc'?'Révolutionnaires':'Police')+' · étape '+last.stage};
      clipP=window.__btRec.stop(card).then(b=>{clipBlob=b&&b.size>20000?b:null;showClip();return clipBlob});
    }else clipP=Promise.resolve(null);
    renderAcct();
  }

  // ---------- vidéo sur l'écran de fin ----------
  let clipURL=null;
  function showClip(){
    const box=$('clipbox');if(!box)return;
    if(!clipBlob){box.hidden=true;return}
    if(clipURL)URL.revokeObjectURL(clipURL);clipURL=URL.createObjectURL(clipBlob);
    const v=$('clipv');v.src=clipURL;v.play().catch(()=>{});
    const ext=window.__btRec.ext(),name='bastille-'+(last?last.score:'partie')+'.'+ext;
    const a=$('clipdl');a.href=clipURL;a.download=name;
    const f=new File([clipBlob],name,{type:clipBlob.type});
    const sh=$('clipshare');sh.hidden=!(navigator.canShare&&navigator.canShare({files:[f]}));
    sh.onclick=async()=>{try{await navigator.share({files:[f],title:'BASTILLE',text:'Mon score à BASTILLE ! À toi de jouer : '+shareLink()})}catch(e){}};
    box.hidden=false;
  }
  function shareLink(){const r=LS.get('bt_refcode');return base()+(r?'?ref='+r:'')}

  // ---------- compte et e-mail ----------
  let pendingEmail='';
  function step(n){['mb1','mb2','mb3'].forEach((id,i)=>{const e=$(id);if(e)e.hidden=(i!==n-1)})}
  function msg(t,cls){const m=$('mailmsg');if(m){m.textContent=t||'';m.className=cls||''}}
  async function renderAcct(){
    const box=$('mailbox');if(!box)return;
    if(!sb||!C.mail){box.hidden=true;return}
    box.hidden=false;
    const u=await user();
    if(u){step(3);$('mbwho').textContent=u.email;$('mbpseudo').textContent=LS.get('bt_pseudo')||'…';
      const r=LS.get('bt_refcode');$('mbref').value=r?base()+'?ref='+r:'';$('mbrefrow').hidden=!r;
      const b=$('mbsend');b.disabled=!last||last.sent;b.textContent=last&&last.sent?'ENVOYÉ ✓':'M\'ENVOYER CE SCORE + LA VIDÉO';
    }else{step(pendingEmail?2:1)}
  }
  async function sendScore(){
    if(!last||last.sent)return;
    const u=await user();if(!u)return;
    const b=$('mbsend');b.disabled=true;msg('Préparation…');
    try{
      await sb.rpc('claim_game',{k:last.gkey});
      const blob=await clipP;
      if(blob&&!last.uploaded){
        msg('Mise en ligne de la vidéo…');
        const path=u.id+'/'+last.gkey+'.'+window.__btRec.ext();
        const up=await sb.storage.from('clips').upload(path,blob,{contentType:window.__btRec.mime(),upsert:false});
        if(!up.error){last.uploaded=path;await sb.rpc('set_game_clip',{k:last.gkey,path})}
      }
      msg('Envoi de l\'e-mail…');
      const {error}=await sb.functions.invoke('send-score',{body:{gkey:last.gkey}});
      if(error)throw error;
      last.sent=true;msg('C\'est parti ! Regarde ta boîte mail.','ok');showMyRank();
    }catch(e){msg('Envoi impossible pour le moment. Réessaie plus tard.','err');b.disabled=false}
    renderAcct();
  }
  function wire(){
    const f1=$('mb1'),f2=$('mb2');if(!f1)return;
    f1.addEventListener('submit',async ev=>{ev.preventDefault();
      const em=$('mail').value.trim();
      if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(em)){msg('Adresse e-mail invalide.','err');return}
      msg('Envoi du code…');
      const {error}=await sb.auth.signInWithOtp({email:em,options:{shouldCreateUser:true,emailRedirectTo:base()}});
      if(error){msg(/rate|seconds/i.test(error.message)?'Patiente un peu avant de redemander un code.':'Impossible d\'envoyer le code.','err');return}
      pendingEmail=em;$('mbto').textContent=em;step(2);msg('E-mail envoyé : entre le code reçu, ou clique sur le lien (regarde aussi les indésirables).');setTimeout(()=>$('mbcode').focus(),50);
    });
    f2.addEventListener('submit',async ev=>{ev.preventDefault();
      const code=$('mbcode').value.replace(/\D/g,'');
      if(code.length<6){msg('Le code fait 6 chiffres.','err');return}
      msg('Vérification…');
      const {error}=await sb.auth.verifyOtp({email:pendingEmail,token:code,type:'email'});
      if(error){msg('Code incorrect ou expiré.','err');return}
      const news=$('mbnews').checked;pendingEmail='';
      try{await sb.rpc('set_news_consent',{ok:news})}catch(e){}
      const ref=LS.get('bt_ref');if(ref){try{const {data}=await sb.rpc('claim_referral',{code:ref});LS.del('bt_ref');if(data>0)toast('BIENVENUE : +'+data+' PIÈCES')}catch(e){}}
      msg('Connecté !','ok');await syncCredits();await renderAcct();
      if(last&&!last.sent)sendScore();
    });
    $('mbback').onclick=()=>{pendingEmail='';step(1);msg('')};
    $('mbsend').onclick=sendScore;
    $('mbout').onclick=async()=>{await sb.auth.signOut();msg('');renderAcct()};
    $('mbcopy').onclick=async()=>{const v=$('mbref').value;try{await navigator.clipboard.writeText(v);msg('Lien copié !','ok')}catch(e){$('mbref').select()}};
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>{wire();syncCredits()});else{wire();syncCredits()}

  // ---------- classement ----------
  const RK={side:'bloc',per:'week',mode:'pts',from:null};
  const fmtT=n=>{n=Math.max(0,n|0);return Math.floor(n/60)+':'+String(n%60).padStart(2,'0')};
  const fmtS=(side,n)=>Number(n||0).toLocaleString('fr-FR')+' pts';
  async function showMyRank(){
    const el=$('mbrank');if(!el||!last||!sb)return;el.textContent='';
    const u=await user();if(!u)return;
    const {data}=await sb.rpc('my_rank',{p_side:last.side,p_period:'week'});
    const r=data&&data[0];if(r)el.textContent='Classement de la semaine : #'+r.rank+' sur '+r.total+' (record '+fmtS(last.side,r.score)+')';
  }
  async function loadRank(){
    const list=$('rkList'),me=$('rkMe');if(!list)return;
    document.querySelectorAll('#rkSide button').forEach(b=>b.classList.toggle('on',b.dataset.v===RK.side));
    document.querySelectorAll('#rkPer button').forEach(b=>b.classList.toggle('on',b.dataset.v===RK.per));
    document.querySelectorAll('#rkMode button').forEach(b=>b.classList.toggle('on',b.dataset.v===RK.mode));const TM=RK.mode==='time';
    list.textContent='';me.textContent='';
    if(!sb){const li=document.createElement('li');li.textContent='Classement indisponible pour le moment.';list.appendChild(li);return}
    const loading=document.createElement('li');loading.className='empty';loading.textContent='Chargement…';list.appendChild(loading);
    const {data,error}=await sb.rpc(TM?'leaderboard_time':'leaderboard',{p_side:RK.side,p_period:RK.per});
    list.textContent='';
    if(error||!data||!data.length){const li=document.createElement('li');li.className='empty';li.textContent=error?'Classement indisponible pour le moment.':TM?'Personne n\'a encore pris la Bastille sur cette période. À toi !':'Personne encore sur cette période. À toi !';list.appendChild(li)}
    else data.forEach(r=>{const li=document.createElement('li');if(r.pseudo===LS.get('bt_pseudo'))li.className='me';
      const a=document.createElement('b');a.textContent='#'+r.rank;const n=document.createElement('span');n.textContent=r.pseudo;
      const d=document.createElement('small');d.textContent=(r.tenue?r.tenue+' · ':'')+(TM?(r.era?r.era+' · ':'')+fmtS(RK.side,r.score):'étape '+r.stage);
      const sc=document.createElement('em');sc.textContent=TM?fmtT(r.time_s):fmtS(RK.side,r.score);
      const mid=document.createElement('div');mid.append(n,d);li.append(a,mid,sc);list.appendChild(li)});
    const u=await user();
    if(u){const {data:m}=await sb.rpc(TM?'my_rank_time':'my_rank',{p_side:RK.side,p_period:RK.per});const r=m&&m[0];me.textContent=r?'Toi ('+(r.pseudo||'')+') : #'+r.rank+' sur '+r.total+' · '+(TM?fmtT(r.time_s):fmtS(RK.side,r.score)):TM?'Tu n\'as pas encore pris la Bastille sur cette période.':'Tu n\'as pas encore de partie classée sur cette période.'}
    else me.textContent=C.mail?'Reçois ton score par e-mail en fin de partie pour entrer au classement.':'Inscription au classement bientôt disponible.';
  }
  function openRank(from){
    const scr=$('s-rank');if(!scr)return;RK.from=from||null;
    if(last&&last.side)RK.side=last.side;if(last&&last.won)RK.mode='time';
    if(from)$(from).hidden=true;scr.hidden=false;loadRank();
  }
  function closeRank(){$('s-rank').hidden=true;if(RK.from)$(RK.from).hidden=false}
  function wireRank(){
    if(!$('s-rank'))return;
    if(!ok){['t-rank','end-rank'].forEach(id=>{const e=$(id);if(e)e.hidden=true});return}
    $('t-rank').onclick=()=>openRank('s-title');
    $('end-rank').onclick=()=>openRank('s-end');
    $('rk-back').onclick=closeRank;
    document.querySelectorAll('#rkSide button').forEach(b=>b.onclick=()=>{RK.side=b.dataset.v;loadRank()});
    document.querySelectorAll('#rkPer button').forEach(b=>b.onclick=()=>{RK.per=b.dataset.v;loadRank()});
    document.querySelectorAll('#rkMode button').forEach(b=>b.onclick=()=>{RK.mode=b.dataset.v;loadRank()});
    $('mbreroll').onclick=async()=>{const {data,error}=await sb.rpc('reroll_pseudo');if(!error&&data){LS.set('bt_pseudo',data);$('mbpseudo').textContent=data}};
    const del=$('mbdel');del.onclick=async()=>{
      if(del.dataset.c!=='1'){del.dataset.c='1';del.textContent='Confirmer la suppression définitive ?';setTimeout(()=>{del.dataset.c='';del.textContent='Supprimer mon compte'},5000);return}
      msg('Suppression…');
      try{const u=await user();if(u){const {data:files}=await sb.storage.from('clips').list(u.id,{limit:1000});if(files&&files.length)await sb.storage.from('clips').remove(files.map(f=>u.id+'/'+f.name))}
        const {error}=await sb.rpc('delete_my_account');if(error)throw error;
        await sb.auth.signOut();['bt_pseudo','bt_refcode'].forEach(k=>LS.del(k));msg('Compte et données supprimés.','ok');renderAcct();
      }catch(e){msg('Suppression impossible pour le moment.','err')}
    };
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',wireRank);else wireRank();

  // ---------- message de vainqueur et signalement de bugs ----------
  const WERR={not_found:'Partie introuvable (le message doit être écrit dans les 2 h).',already:'Tu as déjà laissé un message pour cette victoire.',banned:'Ton compte ne peut plus publier.',length:'Message trop court ou trop long (2 à 280 caractères).',name:'Choisis un pseudo (2 à 24 caractères).',link:'Les liens et les mentions ne sont pas autorisés.',banned_term:'Ce message contient un terme interdit (insulte, haine ou menace).',rate_limited:'Doucement : trop de messages aujourd\'hui.'};
  const errOf=(e,M)=>{const em=(e&&e.message||'').trim();const k=Object.keys(M).sort((x,y)=>y.length-x.length).find(x=>em.includes(x));return k?M[k]:null};
  async function postWin(name,body){
    if(!sb||!last)return 'Le mur est indisponible pour le moment.';
    LS.set('bt_wname',name);
    for(let i=0;i<3;i++){const {error}=await sb.rpc('post_game_comment',{p_gkey:last.gkey,p_visitor:visitor,p_name:name,p_body:body});
      if(!error)return true;if(!/not_found/.test(error.message||'')||i===2)return errOf(error,WERR)||'Publication impossible pour le moment.';await new Promise(r=>setTimeout(r,1500))}
  }
  async function reportBug(body,ctx){
    if(!sb)return 'Envoi impossible pour le moment.';
    const {error}=await sb.rpc('report_bug',{p_visitor:visitor,p_body:body,p_ctx:Object.assign({},ctx||{},{page:location.pathname})});
    if(!error)return true;return /rate_limited/.test(error.message||'')?'Doucement : attends un peu avant d\'envoyer un autre signalement.':'Envoi impossible pour le moment.';
  }
  window.__bt={enabled:()=>ok,gameStart,gameEnd,renderAcct,postWin,reportBug};
})();
