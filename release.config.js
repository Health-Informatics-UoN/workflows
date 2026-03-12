module.exports = {
    "branches": ["main"],
    "tagFormat": "${version}",
    "preset": "angular",
    "repositoryUrl": "https://github.com/Health-Informatics-UoN/nuh-helper.git",
    plugins: [
      '@semantic-release/commit-analyzer',
      '@semantic-release/release-notes-generator',
      '@semantic-release/exec',
      '@semantic-release/github',
    ],
    "initialVersion": "0.0.1"
};
