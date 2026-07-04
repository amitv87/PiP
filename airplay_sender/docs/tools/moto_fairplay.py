#!/usr/bin/env python3
"""
moto_fairplay: run the Motorola SoftMedia receiver's ACTUAL FairPlay offline.

Loads libAirReceiver.so once + a bundled PRE-handshake .data/.bss snapshot, then per call:
  derive(m1, m3, ekey) -> aes_key  (also returns m2, m4)
by emulating  init -> FUN_005c9b08(m1) -> FUN_005c9b08(m3) -> FUN_005c9ebc(ekey).

This is the oracle PiP uses so its stream key matches what the Moto derives.
"""
import struct, time
from unicorn import *
from unicorn.arm64_const import *

HS_VA=0x4c9b08; UNWRAP_VA=0x4c9ebc; CHK_VA=0x47ce38
RW1_VA=0x939f80; RW2_VA=0x98ae60
STACK=0x10000000;STACK_SZ=0x200000; HEAP=0x20000000;HEAP_SZ=0x4000000
STUBS=0x30000000;STUB_SZ=0x10000; TLS=0x11000000;TLS_SZ=0x10000; RET=0x50000000

class MotoFairPlay:
    def __init__(self, so_path, rw1_path, rw2_path, snap_base):
        self.d=open(so_path,"rb").read()
        self.rw1=open(rw1_path,"rb").read(); self.rw2=open(rw2_path,"rb").read()
        self.snap_base=snap_base
        self.base=snap_base
        self._parse()
        self._build()   # map .so, apply relocations, set up stubs+tamper bypass (once)

    def _parse(self):
        d=self.d
        pho=struct.unpack_from("<Q",d,0x20)[0];phn=struct.unpack_from("<H",d,0x38)[0];phe=struct.unpack_from("<H",d,0x36)[0]
        self.loads=[];self.dyn_off=self.dyn_sz=None
        for i in range(phn):
            o=pho+i*phe;t,fl,po,pv,pp,fs,ms,al=struct.unpack_from("<IIQQQQQQ",d,o)
            if t==1:self.loads.append((po,pv,fs,ms))
            if t==2:self.dyn_off,self.dyn_sz=po,fs
        self.dyn={}
        for k in range(self.dyn_sz//16):
            tag,val=struct.unpack_from("<qQ",d,self.dyn_off+k*16)
            if tag==0:break
            self.dyn.setdefault(tag,val)

    def _va2off(self,va):
        for po,pv,fs,ms in self.loads:
            if pv<=va<pv+fs:return po+(va-pv)
    def _symname(self,idx):
        d=self.d;st=self.dyn[6];se=self.dyn.get(11,24);so=self._va2off(st)+idx*se
        n=struct.unpack_from("<I",d,so)[0];v=struct.unpack_from("<Q",d,so+8)[0];sh=struct.unpack_from("<H",d,so+6)[0]
        e=d.index(b"\0",self._va2off(self.dyn[5])+n);return d[self._va2off(self.dyn[5])+n:e].decode("latin1"),v,sh

    def _build(self):
        d=self.d;uc=Uc(UC_ARCH_ARM64,UC_MODE_ARM);self.uc=uc
        max_end=max(pv+ms for po,pv,fs,ms in self.loads)
        msz=(max_end+0xFFF)&~0xFFF; self.msz=msz
        uc.mem_map(self.base,msz)
        for po,pv,fs,ms in self.loads:uc.mem_write(self.base+pv,d[po:po+fs])
        for b,sz in [(STACK,STACK_SZ),(HEAP,HEAP_SZ),(STUBS,STUB_SZ),(TLS,TLS_SZ),(RET&~0xFFF,0x1000)]:uc.mem_map(b,sz)
        uc.reg_write(UC_ARM64_REG_TPIDR_EL0,TLS);uc.mem_write(TLS+0x28,struct.pack("<Q",0x1122334455667788))
        # stubs + relocations
        self.stub_syms={};self.imp={};self.nxt=[STUBS]
        self._apply(self.dyn[7],self.dyn[8],True); self._apply(self.dyn[23],self.dyn[2],True)
        # heap + tamper-check fake object
        self.heap=[HEAP]
        ret0=self._stub("__ret0");fvt=self._halloc(0x200)
        for i in range(0,0x200,8):uc.mem_write(fvt+i,struct.pack("<Q",ret0))
        self.fake=self._halloc(0x80);uc.mem_write(self.fake,struct.pack("<Q",fvt));self.CHK=self.base+CHK_VA
        self.heap_base_reset=self.heap[0]   # heap watermark after fixed setup
        # range-scoped hooks (NOT per-instruction): stubs region + the single checker-getter addr
        uc.hook_add(UC_HOOK_CODE,self._hc_stub,begin=STUBS,end=STUBS+STUB_SZ-1)
        uc.hook_add(UC_HOOK_CODE,self._hc_chk,begin=self.CHK,end=self.CHK)
        # persistent scratch buffers (reused each call)
        self.fp=self._halloc(0x400);self.op=self._halloc(8);self.olp=self._halloc(4);self.flp=self._halloc(1)
        self.mbuf=self._halloc(0x400)   # message input buffer
        self.ekbuf=self._halloc(0x100)
        self._reset_watermark=self.heap[0]

    def _stub(self,n):
        if n not in self.imp:
            a=self.nxt[0];self.nxt[0]+=8;self.imp[n]=a;self.stub_syms[a]=n
            self.uc.mem_write(a,struct.pack("<I",0xd65f03c0)+b"\0\0\0\0")
        return self.imp[n]
    def _apply(self,off,size,ext):
        if not off:return
        d=self.d;b=self._va2off(off)
        for i in range(size//24):
            ro,ri,ra=struct.unpack_from("<QQq",d,b+i*24);typ=ri&0xffffffff;sym=ri>>32
            if typ==1027 and not ext:self.uc.mem_write(self.base+ro,struct.pack("<Q",self.base+ra))
            elif typ in(1025,1026,257) and ext:
                nm,v,sh=self._symname(sym);t=(self.base+v) if sh!=0 else self._stub(nm)
                if typ==257:t+=ra
                self.uc.mem_write(self.base+ro,struct.pack("<Q",t))
    def _halloc(self,n):n=(n+15)&~15;p=self.heap[0];self.heap[0]+=n;return p
    def _hc_chk(self,uc,addr,sz,u):
        uc.reg_write(UC_ARM64_REG_X0,self.fake);uc.reg_write(UC_ARM64_REG_PC,uc.reg_read(UC_ARM64_REG_LR))
    def _hc_stub(self,uc,addr,sz,u):
        nm=self.stub_syms.get(addr,"?")
        x=[uc.reg_read(r) for r in(UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2,UC_ARM64_REG_X3)]
        uc.reg_write(UC_ARM64_REG_X0,self._disp(nm,x)&0xffffffffffffffff)
        uc.reg_write(UC_ARM64_REG_PC,uc.reg_read(UC_ARM64_REG_LR))
    def _disp(self,nm,x):
        uc=self.uc
        if nm in("memcpy","__memcpy_chk","memmove"):uc.mem_write(x[0],bytes(uc.mem_read(x[1],x[2])));return x[0]
        if nm in("memset","__memset_chk"):uc.mem_write(x[0],bytes([x[1]&0xff])*x[2]);return x[0]
        if nm in("malloc","valloc","__op_alloc"):return self._halloc(x[0] or 0x200)
        if nm=="calloc":p=self._halloc(x[0]*x[1]);uc.mem_write(p,b"\0"*(x[0]*x[1]));return p
        if nm=="strlen":
            n=0
            while uc.mem_read(x[0]+n,1)[0]!=0:n+=1
            return n
        return 0

    def _overlay(self):
        # restore PRE-handshake .data/.bss (the handshake mutates globals) + reset heap/allocator
        self.uc.mem_write(self.base+RW1_VA,self.rw1); self.uc.mem_write(self.base+RW2_VA,self.rw2)
        # re-apply external relocs AFTER the overlay so import GOT slots point at our stubs
        # (the snapshot holds live-libc addresses that would otherwise clobber them)
        self._apply(self.dyn[7],self.dyn[8],True); self._apply(self.dyn[23],self.dyn[2],True)
        gv=struct.unpack("<Q",self.uc.mem_read(self.base+0xab0b08,8))[0]
        if not(self.base<=gv<self.base+self.msz):self.uc.mem_write(self.base+0xab0b08,struct.pack("<Q",self._stub("__op_alloc")))
        self.heap[0]=self._reset_watermark

    def _call(self,entry,args):
        uc=self.uc
        for i,v in enumerate(args):uc.reg_write((UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2,UC_ARM64_REG_X3,UC_ARM64_REG_X4,UC_ARM64_REG_X5)[i],v)
        uc.reg_write(UC_ARM64_REG_SP,STACK+STACK_SZ-0x1000);uc.reg_write(UC_ARM64_REG_LR,RET)
        uc.emu_start(entry,RET,count=300_000_000)
    def _out(self):
        p=struct.unpack("<Q",self.uc.mem_read(self.op,8))[0];l=struct.unpack("<I",self.uc.mem_read(self.olp,4))[0]
        return (bytes(self.uc.mem_read(p,l)) if (p and 0<l<8192) else b"")

    def derive(self, ctx0, m1, m3, ekey):
        """Run the full FairPlay: returns (m2, m4, aes_key)."""
        uc=self.uc
        self._overlay()
        uc.mem_write(self.fp, ctx0.ljust(0x400,b"\0"))
        uc.mem_write(self.mbuf, m1); uc.mem_write(self.op,b"\0"*8);uc.mem_write(self.olp,b"\0"*4)
        self._call(self.base+HS_VA,[self.fp,self.mbuf,len(m1),self.op,self.olp,self.flp]); m2=self._out()
        uc.mem_write(self.mbuf, m3); uc.mem_write(self.op,b"\0"*8);uc.mem_write(self.olp,b"\0"*4)
        self._call(self.base+HS_VA,[self.fp,self.mbuf,len(m3),self.op,self.olp,self.flp]); m4=self._out()
        uc.mem_write(self.ekbuf, ekey); uc.mem_write(self.op,b"\0"*8);uc.mem_write(self.olp,b"\0"*4)
        self._call(self.base+UNWRAP_VA,[self.fp,self.ekbuf,len(ekey),self.op,self.olp])
        p=struct.unpack("<Q",uc.mem_read(self.op,8))[0]
        aes=bytes(uc.mem_read(p,16)) if p else b"\0"*16
        return m2,m4,aes

if __name__=="__main__":
    # Self-test: reproduce a captured session's aes_key from the bundled assets.
    #   Assets dir (default: $MOTO_FP_ASSETS or ./assets) must contain, from fp_snapshot.js:
    #     libAirReceiver.so, snap_base.txt, snap_rw1.bin, snap_rw2.bin, snap_ctx0.bin,
    #     snap_msg1.bin(m1), snap_msg2.bin(m3), snap_ekey.bin, snap_aes.bin, snap_out1/2.bin
    import os, sys
    A=sys.argv[1] if len(sys.argv)>1 else os.environ.get("MOTO_FP_ASSETS",
        os.path.join(os.path.dirname(os.path.abspath(__file__)),"assets"))
    def rd(n): return open(os.path.join(A,n),"rb").read()
    base=int(rd("snap_base.txt").decode().strip(),16)
    mf=MotoFairPlay(os.path.join(A,"libAirReceiver.so"),
                    os.path.join(A,"snap_rw1.bin"), os.path.join(A,"snap_rw2.bin"), base)
    ctx0=rd("snap_ctx0.bin"); m1=rd("snap_msg1.bin"); m3=rd("snap_msg2.bin")
    ekey=rd("snap_ekey.bin"); want=rd("snap_aes.bin")
    out1=rd("snap_out1.bin"); out2=rd("snap_out2.bin")
    N=3; t0=time.time()
    for _ in range(N): m2,m4,aes=mf.derive(ctx0,m1,m3,ekey)
    print("m2 match:",m2==out1,"| m4 match:",m4==out2,"| aes match:",aes==want)
    print("aes:",aes.hex(),"| per-call: %.2f s"%((time.time()-t0)/N))
