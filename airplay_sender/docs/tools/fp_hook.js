/*
 * fp_hook.js -- DERIVATION-CRACK phase.
 * Capture, for one macOS->Moto session: SETUP data fields (eiv/ekey/scid via FUN_00877480),
 * FairPlay aes_key (unwrap), every SHA256/SHA512 input+digest, and the final video key
 * (AES_set_encrypt_key). Then offline: find the SHA whose digest[:16] == video key.
 * libAirReceiver.so 5.1.7. offset = ghidra - 0x100000.
 */
'use strict';
var MODULE='libAirReceiver.so';
var _base=null;
rpc.exports={ ping:function(){ var m=Process.findModuleByName(MODULE); return 'pid='+Process.id+' mod='+(m?m.base:'none'); } };

var OFF={
  unwrap: 0x4c9ebc,   // FUN_005c9ebc(fp_ctx,ekey,len,&out,&outlen)  -> aes_key
  extract:0x777480,   // FUN_00877480(plistVal,&buf,&len)  -> eiv/ekey/scid data fields
  aesset: 0x7b6de8,   // AES_set_encrypt_key(userKey,bits,key)  -> final video key
  sha512:  0x791074, sha512_upd:0x790ec8, sha512_fin:0x790d40,
  sha256:  0x78ec5c, sha256_upd:0x78ea14, sha256_fin:0x78eb20,
  sha1_fin:0x78d520, md5:0x762ee4,
};
function rawhex(p,len){ if(!p||p.isNull()||len<=0||len>4096) return '(null/'+len+')';
  try{var b=new Uint8Array(p.readByteArray(len)),s='';for(var i=0;i<b.length;i++)s+=('0'+b[i].toString(16)).slice(-2);return s;}
  catch(e){return '(read-fail)';} }
function findExport(name){ try{ if(Module.getGlobalExportByName) return Module.getGlobalExportByName(name);}catch(e){}
  try{var m=Process.getModuleByName('libc.so'); if(m) return (m.findExportByName?m.findExportByName(name):m.getExportByName(name));}catch(e){} return null; }

function install(base){
  _base=base; console.log('[fp_hook] '+MODULE+' base='+base);

  // FairPlay unwrap: ekey -> aes_key
  Interceptor.attach(base.add(OFF.unwrap),{
    onEnter:function(a){ this.ek=a[1]; this.n=a[2].toInt32(); this.op=a[3]; this.ol=a[4];
      console.log('\n##### unwrap ekey('+this.n+'B): '+rawhex(this.ek,this.n)); },
    onLeave:function(){ try{ console.log('##### unwrap => aes_key: '+rawhex(this.op.readPointer(), this.ol.readU32())); }catch(e){} }
  });

  // SETUP data fields (eiv/ekey/scid/shk): FUN_00877480(val,&buf,&len)
  var extSeen={};
  Interceptor.attach(base.add(OFF.extract),{
    onEnter:function(a){ this.pb=a[1]; this.pl=a[2]; },
    onLeave:function(){ try{ var b=this.pb.readPointer(), l=this.pl.readU32();
      if(l>0&&l<=128){ var h=rawhex(b,l); if(!extSeen[h]){ extSeen[h]=1; console.log('[FIELD] len='+l+' '+h); } } }catch(e){} }
  });

  // integer SETUP fields: FUN_00877414(val,&out_i64) -> et/timingPort/type/streamConnectionID
  var intSeen={};
  Interceptor.attach(base.add(0x777414),{
    onEnter:function(a){ this.po=a[1]; },
    onLeave:function(){ try{ var v=this.po.readU64(); var s=v.toString();
      if(intSeen[s])return; intSeen[s]=1;
      console.log('[INT] '+s+'  (0x'+v.toString(16)+')'); }catch(e){} }
  });

  // SHA one-shot: SHA(data,len,md)
  function shaOne(name){ var seen={}; return { onEnter:function(a){ this.d=a[0]; this.l=a[1].toInt32(); this.md=a[2]; },
    onLeave:function(){ if(this.l<0||this.l>512) return; var inp=rawhex(this.d,this.l);
      if(seen[inp])return; seen[inp]=1;
      console.log('\n[SHA] '+name+'  in('+this.l+')='+inp+'\n      digest16='+rawhex(this.md,16)); } }; }
  Interceptor.attach(base.add(OFF.sha512), shaOne('SHA512'));
  Interceptor.attach(base.add(OFF.sha256), shaOne('SHA256'));
  Interceptor.attach(base.add(OFF.md5),    shaOne('MD5'));

  // SHA streaming: track ctx->input via Update, dump on Final
  var acc={};
  function updHook(){ return { onEnter:function(a){ var c=a[0].toString(); var l=a[2].toInt32();
      if(l>0&&l<=256){ acc[c]=(acc[c]||'')+rawhex(a[1],l); if(acc[c].length>2048) acc[c]=acc[c].slice(0,2048); } } }; }
  function finHook(name){ var seen={}; return { onEnter:function(a){ this.md=a[0]; this.c=a[1]?a[1].toString():null; },
    onLeave:function(){ var inp=this.c?acc[this.c]:null; if(!inp) return; if(seen[inp])return; seen[inp]=1;
      console.log('\n[SHA*] '+name+'  in='+inp+'\n       digest16='+rawhex(this.md,16)); if(this.c) delete acc[this.c]; } }; }
  Interceptor.attach(base.add(OFF.sha512_upd), updHook());
  Interceptor.attach(base.add(OFF.sha256_upd), updHook());
  Interceptor.attach(base.add(OFF.sha512_fin), finHook('SHA512*'));
  Interceptor.attach(base.add(OFF.sha256_fin), finHook('SHA256*'));

  // final video key + BACKTRACE to the deriving function
  var mod=Process.findModuleByName(MODULE), lo=mod.base, hi=mod.base.add(mod.size);
  var kseen={};
  Interceptor.attach(base.add(OFF.aesset),{ onEnter:function(a){ var nb=(a[1].toInt32()/8)|0; if(nb<=0||nb>32)return;
    var h=rawhex(a[0],nb); if(kseen[h])return; kseen[h]=1;
    console.log('\n***** AES key set ('+(nb*8)+'b): '+h);
    try{ var bt=Thread.backtrace(this.context, Backtracer.ACCURATE);
      var frames=bt.filter(function(p){return p.compare(lo)>=0&&p.compare(hi)<0;})
                   .slice(0,8).map(function(p){return 'base+0x'+p.sub(lo).toString(16);});
      console.log('      caller-chain: '+frames.join(' <- ')); }catch(e){ console.log('      bt err '+e); }
  } });

  console.log('[fp_hook] derivation hooks installed. Start the mirror now.');
}

function waitForModule(){
  var m=Process.findModuleByName(MODULE); if(m){ install(m.base); return; }
  var dl=findExport('android_dlopen_ext')||findExport('dlopen');
  if(dl){ Interceptor.attach(dl,{ onEnter:function(a){try{this.p=a[0].readCString();}catch(e){}},
    onLeave:function(){ if(this.p&&this.p.indexOf(MODULE)!==-1){var mm=Process.findModuleByName(MODULE);if(mm)install(mm.base);} } });
    console.log('[fp_hook] watching dlopen...'); }
  else setTimeout(waitForModule,500);
}
waitForModule();
