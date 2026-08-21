const assert=require('node:assert/strict');
const geometry=require('./geometry.js');

const edge={id:1,from:1,to:2};
const nodes=[{id:1,x:0,y:0},{id:2,x:0,y:240},{id:3,x:0,y:120}];
const preview=geometry.previewRoute(edge,nodes,'down');
assert.equal(geometry.clearPreview(preview,edge,nodes),true);
assert.deepEqual(preview[0],{x:0,y:28});
assert.deepEqual(preview.at(-1),{x:0,y:212});
assert.match(geometry.routePath(preview,'angular'),/^M /);
assert.doesNotMatch(geometry.routePath(preview,'angular'),/ Q /);
assert.match(geometry.routePath(preview,'curvy'),/ Q /);
const vertical=[{x:10,y:0},{x:10,y:20}];
assert.deepEqual(geometry.shortenTarget(vertical,7),[{x:10,y:0},{x:10,y:13}]);
assert.deepEqual(vertical,[{x:10,y:0},{x:10,y:20}]);
assert.deepEqual(geometry.displayedNodes([{id:1,x:0,y:0}],new Map([[1,{x:40,y:50}]])),[{id:1,x:40,y:50}]);
assert.equal(geometry.responseMatches('session:2','session:1'),false);
assert.equal(geometry.responseMatches('session:2','session:2'),true);

const portNodes=[
  {id:10,x:100,y:100,width:200,height:80,ports:[{id:'send',role:'output',side:'right',offset:.25}]},
  {id:11,x:420,y:240,width:120,height:100,ports:[{id:'receive',role:'input',side:'left',offset:.75}]},
];
const portEdge={from:10,to:11,source_port:'send',target_port:'receive'};
const portPreview=geometry.previewRoute(portEdge,portNodes);
assert.deepEqual(portPreview[0],{x:200,y:80});
assert.deepEqual(portPreview.at(-1),{x:360,y:265});
assert.equal(portPreview.slice(0,-1).every((point,index)=>point.x===portPreview[index+1].x||point.y===portPreview[index+1].y),true);
assert.equal(geometry.clearPreview(portPreview,portEdge,portNodes),true);
assert.match(geometry.routePath(portPreview,'rounded'),/ Q /);
console.log('node editor geometry tests passed');
