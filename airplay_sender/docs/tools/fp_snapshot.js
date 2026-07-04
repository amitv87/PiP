/*
 * fp_snapshot.js -- capture a consistent state snapshot at the moment FUN_005c9ebc runs,
 * so the unwrap can be replayed offline in Unicorn:
 *   - the module's writable segments (.data/.bss = runtime-computed whitebox tables + globals)
 *   - the fp_ctx (arg0) region  (session state incl. the 276-byte context)
 *   - the ekey (arg1)           (input)
 *   - the aes_key (output)      (ground truth)
 * plus the module base (so the emulator can map at the same address -> snapshot pointers valid).
 */
'use strict';
var MODULE='libAirReceiver.so';
var UNWRAP=0x4c9ebc;
// writable LOAD segments (there is an unmapped gap between them):
var RW1_VA=0x939f80, RW1_LEN=0x4cee0;     // data
var RW2_VA=0x98ae60, RW2_LEN=0x15fa80;    // data + bss (memsz)
var _base=null;
rpc.exports={ ping:function(){ return 'pid='+Process.id+' base='+(_base||'?'); } };

// read [off,len] from module base in 0x1000 chunks; unreadable pages -> zeros
function dumpRegion(base, off, len){
  var out=new Uint8Array(len);
  for(var p=0; p<len; p+=0x1000){
    var n=Math.min(0x1000, len-p);
    try{ out.set(new Uint8Array(base.add(off+p).readByteArray(n)), p); }catch(e){}
  }
  return out.buffer;
}

var HS=0x4c9b08;   // FUN_005c9b08 (FairPlay message processor: m1, m3)
function install(base){
  _base=base;
  console.log('[snap] '+MODULE+' base='+base);
  // capture the handshake: pre-handshake .data/.bss (call#1), m1/m3 inputs, m2/m4 outputs,
  // and the fp_ctx after each step
  var hscall=0;
  Interceptor.attach(base.add(HS),{
    onEnter:function(a){
      hscall++;
      this.c=hscall; this.fp=a[0]; this.op=a[3]; this.ol=a[4];
      var n=a[2].toInt32();
      if(hscall===1){
        send({t:'ctx0'}, a[0].readByteArray(0x235));                // initial fp_ctx (post-init)
        send({t:'rw1', va:RW1_VA}, dumpRegion(base, RW1_VA, RW1_LEN)); // PRE-handshake globals
        send({t:'rw2', va:RW2_VA}, dumpRegion(base, RW2_VA, RW2_LEN));
      }
      send({t:'msg'+hscall, n:n}, n>0 ? a[1].readByteArray(n) : null);
      console.log('[snap] HS call#'+hscall+' msg len='+n);
    },
    onLeave:function(){
      try{ var p=this.op.readPointer(), l=this.ol.readU32();
        if(p && !p.isNull() && l>0 && l<4096) send({t:'out'+this.c, l:l}, p.readByteArray(l)); // m2/m4
        send({t:'fpafter'+this.c}, this.fp.readByteArray(0x235));    // fp_ctx after m1 / after m3
      }catch(e){ console.log('[snap] HS leave err '+e); }
    }
  });
  Interceptor.attach(base.add(UNWRAP),{
    onEnter:function(a){
      this.op=a[3]; this.ol=a[4];
      var n=a[2].toInt32();
      console.log('[snap] unwrap hit: ekey len='+n);
      send({t:'base', base: base.toString()});
      send({t:'ctx'},  a[0].readByteArray(0x800));   // fp_ctx at unwrap (has real context276)
      send({t:'ekey', n:n}, a[1].readByteArray(n));
      // (rw1/rw2 now captured PRE-handshake at the first FUN_005c9b08 call)
    },
    onLeave:function(){
      try{ var p=this.op.readPointer(), l=this.ol.readU32();
        send({t:'aes', l:l}, p.readByteArray(l>0&&l<256?l:16));
        console.log('[snap] aes_key captured (len='+l+') -- snapshot complete');
      }catch(e){ console.log('[snap] leave err '+e); }
    }
  });
  console.log('[snap] unwrap hook installed; start the mirror.');
}
function findExport(n){ try{ if(Module.getGlobalExportByName) return Module.getGlobalExportByName(n);}catch(e){}
  try{var m=Process.getModuleByName('libc.so'); if(m) return m.findExportByName(n);}catch(e){} return null; }
function waitForModule(){
  var m=Process.findModuleByName(MODULE); if(m){ install(m.base); return; }
  var dl=findExport('android_dlopen_ext')||findExport('dlopen');
  if(dl) Interceptor.attach(dl,{ onEnter:function(a){try{this.p=a[0].readCString();}catch(e){}},
    onLeave:function(){ if(this.p&&this.p.indexOf(MODULE)!==-1){var mm=Process.findModuleByName(MODULE);if(mm)install(mm.base);} } });
  else setTimeout(waitForModule,500);
}
waitForModule();
