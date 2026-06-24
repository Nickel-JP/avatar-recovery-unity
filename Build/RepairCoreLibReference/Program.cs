using System;
using System.Collections.Generic;
using System.IO;

using Mono.Cecil;

if (args.Length == 0)
{
    Console.Error.WriteLine("Usage: RepairCoreLibReference <dll-path>");
    return 1;
}

var dllPath = args[0];
if (!File.Exists(dllPath))
{
    Console.Error.WriteLine($"File not found: {dllPath}");
    return 1;
}

var tempPath = dllPath + ".corelib-repair.tmp";
int typeRefFixed = 0;
int asmRefRemoved = 0;

using (var asm = AssemblyDefinition.ReadAssembly(dllPath))
{
    var module = asm.MainModule;
    AssemblyNameReference mscorlib = null;
    foreach (var aref in module.AssemblyReferences)
    {
        if (aref.Name == "mscorlib") { mscorlib = aref; break; }
    }

    if (mscorlib == null)
    {
        Console.WriteLine("SKIP: mscorlib reference not found");
        return 0;
    }

    foreach (var tref in module.GetTypeReferences())
    {
        if (tref.Scope != null && tref.Scope.Name == "System.Private.CoreLib")
        {
            tref.Scope = mscorlib;
            typeRefFixed++;
        }
    }

    var toRemove = new List<AssemblyNameReference>();
    foreach (var aref in module.AssemblyReferences)
    {
        if (aref.Name == "System.Private.CoreLib")
            toRemove.Add(aref);
    }
    foreach (var aref in toRemove)
    {
        module.AssemblyReferences.Remove(aref);
        asmRefRemoved++;
    }

    asm.Write(tempPath);
}

File.Move(tempPath, dllPath, overwrite: true);
Console.WriteLine($"TypeRefsFixed={typeRefFixed} AsmRefsRemoved={asmRefRemoved}");
return 0;
