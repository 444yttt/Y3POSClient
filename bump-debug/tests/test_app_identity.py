"""Execute the pinned ARM64 registry lookup with CPU-only memory/call fixtures.

This does not execute Bump as an app or contact its services. The actual lookup
and Bump-getter instructions run; unrelated Swift copy/equality calls use stubs.
"""
import hashlib
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import (UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2,
    UC_ARM64_REG_X3, UC_ARM64_REG_X8, UC_ARM64_REG_X19, UC_ARM64_REG_X20,
    UC_ARM64_REG_X21, UC_ARM64_REG_X22, UC_ARM64_REG_X23, UC_ARM64_REG_X24,
    UC_ARM64_REG_LR, UC_ARM64_REG_SP, UC_ARM64_REG_PC)

SPEC = importlib.util.spec_from_file_location('identity_packager',Path(__file__).resolve().parents[1]/'scripts/package_ipa.py')
PACK = importlib.util.module_from_spec(SPEC);sys.modules[SPEC.name]=PACK;SPEC.loader.exec_module(PACK)
FIXTURES=Path(__file__).parent/'fixtures'
LOOKUP=(FIXTURES/'galaxy-current-arm64.bin').read_bytes()
GETTER=(FIXTURES/'galaxy-bump-getter-arm64.bin').read_bytes()
BASE=0x100000000

def small_string(value):
    raw=value.encode();assert len(raw)<=15
    return struct.unpack('<QQ',raw.ljust(15,b'\0')+bytes([0xE0|len(raw)]))

def native_entry(scheme,tag):
    data=bytearray(bytes([tag])*80)
    struct.pack_into('<QQ',data,0x10,*small_string(scheme))
    return bytes(data)

def execute_lookup(*,patched,actual_scheme='amounknown',entries=('amotilt','amolocation','amosugar')):
    uc=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
    for address,size in [(BASE+0x363000,0x1000),(BASE+0xc18000,0x1000),
                         (BASE+0x6143000,0x1000),(BASE+0x809c000,0x1000),
                         (BASE+0x8688000,0x1000),(0x20000000,0x10000),
                         (0x30000000,0x10000),(0x40000000,0x1000)]:uc.mem_map(address,size)
    code=bytearray(LOOKUP)
    if patched:
        for offset,expected,replacement in PACK.APP_IDENTITY_PATCHES:
            index=offset-0x363c38;assert code[index:index+4]==expected;code[index:index+4]=replacement
    uc.mem_write(BASE+0x363c38,bytes(code));uc.mem_write(BASE+0x3636f4,GETTER)
    uc.mem_write(BASE+0x809c160,struct.pack('<q',-1));uc.mem_write(BASE+0x809c178,struct.pack('<q',-1))
    array=0x20000000;info=0x20001000;info_pointer=0x20002000;output=0x20003000
    uc.mem_write(BASE+0x8688e38,struct.pack('<Q',array));uc.mem_write(array+0x10,struct.pack('<Q',len(entries)))
    expected=None
    for index,scheme in enumerate(entries):
        entry=native_entry(scheme,0x30+index);uc.mem_write(array+0x20+80*index,entry)
        if scheme=='amolocation':expected=entry
    uc.mem_write(BASE+0x8688d48,native_entry('amolocation',0xB0))
    uc.mem_write(info+0xB0,struct.pack('<QQ',*small_string(actual_scheme)))
    uc.mem_write(info_pointer,struct.pack('<Q',info))
    uc.reg_write(UC_ARM64_REG_SP,0x3000f000);uc.reg_write(UC_ARM64_REG_LR,0x40000000);uc.reg_write(UC_ARM64_REG_X8,output)
    preserved={reg:0x12340000+index for index,reg in enumerate([UC_ARM64_REG_X19,UC_ARM64_REG_X20,UC_ARM64_REG_X21,UC_ARM64_REG_X22,UC_ARM64_REG_X23,UC_ARM64_REG_X24])}
    for reg,value in preserved.items():uc.reg_write(reg,value)
    state={'fatal':False,'returned':False,'bump_getter_executed':False,'copies':0}
    def hook(cpu,address,size,user):
        del size,user
        def ret():cpu.reg_write(UC_ARM64_REG_PC,cpu.reg_read(UC_ARM64_REG_LR))
        if address==BASE+0x3636f4:state['bump_getter_executed']=True
        if address==BASE+0xc18260:cpu.reg_write(UC_ARM64_REG_X0,info_pointer);ret()
        elif address==BASE+0x363d98:
            cpu.mem_write(cpu.reg_read(UC_ARM64_REG_X0),bytes(cpu.mem_read(cpu.reg_read(UC_ARM64_REG_X1),80)));state['copies']+=1;ret()
        elif address==BASE+0x363640:
            cpu.mem_write(cpu.reg_read(UC_ARM64_REG_X1),bytes(cpu.mem_read(cpu.reg_read(UC_ARM64_REG_X0),80)));ret()
        elif address==BASE+0x6143c88:
            left=(cpu.reg_read(UC_ARM64_REG_X0),cpu.reg_read(UC_ARM64_REG_X1));right=(cpu.reg_read(UC_ARM64_REG_X2),cpu.reg_read(UC_ARM64_REG_X3));cpu.reg_write(UC_ARM64_REG_X0,int(left==right));ret()
        elif address==BASE+0x363d40:ret()
        elif address==BASE+0x363df8:state['fatal']=True;cpu.emu_stop()
        elif address==0x40000000:state['returned']=True;cpu.emu_stop()
    uc.hook_add(UC_HOOK_CODE,hook);uc.emu_start(BASE+0x363c38,0x40000004,count=3000)
    state['result']=bytes(uc.mem_read(output,80));state['expected']=expected
    state['callee_registers_preserved']=all(uc.reg_read(reg)==value for reg,value in preserved.items())
    return state

class AppIdentityTests(unittest.TestCase):
    def test_fixtures_match_reviewed_code_hashes(self):
        self.assertEqual(hashlib.sha256(LOOKUP).hexdigest(),PACK.REGISTRY_LOOKUP_SHA256)
        self.assertEqual(hashlib.sha256(GETTER).hexdigest(),PACK.BUMP_GETTER_SHA256)

    def test_original_unknown_configuration_reproduces_the_assertion(self):
        r=execute_lookup(patched=False);self.assertTrue(r['fatal']);self.assertFalse(r['returned'])

    def test_original_canonical_configuration_returns_full_bump_entry(self):
        r=execute_lookup(patched=False,actual_scheme='amolocation');self.assertTrue(r['returned']);self.assertEqual(r['result'],r['expected']);self.assertFalse(r['bump_getter_executed'])

    def test_patched_unknown_or_renamed_configuration_selects_native_bump(self):
        for scheme in ['amounknown','renamed','amolocation','amotilt']:
            with self.subTest(scheme=scheme):
                r=execute_lookup(patched=True,actual_scheme=scheme);self.assertTrue(r['returned']);self.assertFalse(r['fatal']);self.assertTrue(r['bump_getter_executed']);self.assertEqual(r['result'],r['expected']);self.assertTrue(r['callee_registers_preserved'])

    def test_native_search_handles_bump_at_every_array_position(self):
        for entries in [('amolocation','amotilt'),('amotilt','amolocation'),('amosugar','amotilt','amolocation')]:
            with self.subTest(entries=entries):
                r=execute_lookup(patched=True,entries=entries);self.assertTrue(r['returned']);self.assertEqual(r['result'],r['expected'])

    def test_patch_does_not_disable_failure_if_bump_is_absent(self):
        for entries in [(),('amotilt','amosugar')]:
            with self.subTest(entries=entries):
                r=execute_lookup(patched=True,entries=entries);self.assertTrue(r['fatal']);self.assertFalse(r['returned'])

    def test_patcher_rejects_wrong_uuid_or_changed_code(self):
        data=bytearray(0x364000);uuid_command=struct.pack('<II16s',0x1B,24,bytes.fromhex('ea3612276ee13979b8df242f24fe47dc'))
        data[:32]=struct.pack('<8I',0xFEEDFACF,0x100000C,0,2,1,24,0,0);data[32:56]=uuid_command
        data[0x363c38:0x363d40]=LOOKUP;data[0x3636f4:0x363720]=GETTER
        result,receipt=PACK._patch_app_identity(bytes(data));self.assertEqual(receipt['bytes_replaced'],12)
        expected=bytearray(data)
        for offset,old,new in PACK.APP_IDENTITY_PATCHES:self.assertEqual(data[offset:offset+4],old);expected[offset:offset+4]=new
        self.assertEqual(result,bytes(expected))
        for offset in [40,0x363c40,0x3636f8]:
            bad=bytearray(data);bad[offset]^=1
            with self.subTest(offset=offset),self.assertRaises(PACK.PackagingError):PACK._patch_app_identity(bytes(bad))
        with self.assertRaises(PACK.PackagingError):PACK._patch_app_identity(result)

if __name__=='__main__':unittest.main()
