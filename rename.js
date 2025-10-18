const fs = require('fs');
const path = require('path');

async function traverseDir(dir, callback) {
  const entries = await fs.promises.readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await traverseDir(fullPath, callback);
    } else {
      await callback(fullPath);
    }
  }
}

async function renameFilesAndFolders(dir, oldPascal, newPascal) {
  const entries = await fs.promises.readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    const newName = entry.name
      .replaceAll(oldPascal, newPascal)
      .replaceAll(oldPascal.toLowerCase(), newPascal.toLowerCase());
    const newFullPath = path.join(dir, newName);
    if (newFullPath !== fullPath) {
      console.info("Renamed", fullPath, "to", newFullPath)
      await fs.promises.rename(fullPath, newFullPath);
    }
    if (entry.isDirectory()) {
      await renameFilesAndFolders(newFullPath, oldPascal, newPascal);
    }
  }
}

async function replaceInFileContents(dir, oldPascal, newPascal) {
  await traverseDir(dir, async (filePath) => {
    if (fs.lstatSync(filePath).isDirectory() || fs.lstatSync(filePath).isSymbolicLink()) {
      return
    }
    const content = await fs.promises.readFile(filePath, 'utf8');
    const updatedContent = content
      .replaceAll(oldPascal, newPascal)
      .replaceAll(oldPascal.toLowerCase(), newPascal.toLowerCase());
    if (content !== updatedContent) {
      console.info("Updated", filePath)
      await fs.promises.writeFile(filePath, updatedContent, 'utf8');
    }
  });
}

(async () => {
  const oldPascal = (process.argv[2] ?? "").trim()
  const newPascal = (process.argv[3] ?? "").trim()
  console.log({oldPascal, newPascal})
  if (oldPascal.length > 4 && newPascal.length > 4) {
    await renameFilesAndFolders(__dirname, oldPascal, newPascal);
    await replaceInFileContents(__dirname, oldPascal, newPascal);
  } else {
    console.error("Missing args")
  }
})();
