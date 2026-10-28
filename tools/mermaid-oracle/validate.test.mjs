import test from 'node:test';
import assert from 'node:assert/strict';
import {differences} from './contracts.mjs';
import {geometryDifferences,layoutMetrics,nonFinite,invalidGeometry,parityProblems} from './validate.mjs';
test('semantics never tolerate a number, missing property, or list-order difference',()=>{
 assert.equal(differences({a:1},{a:1.00001}).length,1);
 assert.equal(differences({a:[]},{}).length,1);
 assert.ok(differences(['A','B'],['B','A']).length);
});
const box={x:0,y:0,width:100,height:50};
const geometry={nodes:[{id:'A',box}],edges:[],groups:[],labels:[]};
test('geometry tolerance is in CSS pixels and cannot hide missing or duplicated nodes',()=>{
 assert.deepEqual(geometryDifferences(geometry,geometry),[]);
 assert.ok(geometryDifferences(geometry,{...geometry,nodes:[]}).length);
 assert.ok(geometryDifferences(geometry,{...geometry,nodes:[...geometry.nodes,...geometry.nodes]}).length);
 assert.equal(geometryDifferences(geometry,{...geometry,nodes:[{id:'A',box:{...box,width:101}}]}).length,0);
 assert.equal(geometryDifferences(geometry,{...geometry,nodes:[{id:'A',box:{...box,width:101.01}}]}).length,1);
});
test('measurement and placement errors stay separate',()=>{
 const moved={...geometry,nodes:[{id:'A',box:{...box,x:30,y:40}}]};
 const m=layoutMetrics(geometry,moved).nodes;
 assert.equal(m.max_size_error,0);assert.equal(m.mean_position_error,50);
});
test('nonfinite observations cannot pass silently',()=>{
 assert.deepEqual(nonFinite({nodes:[{x:Infinity,y:NaN}]}),['$.nodes[0].x','$.nodes[0].y']);
});

test('serialized null and missing numeric fields cannot conceal nonfinite native output',()=>{
 const valid={...geometry,view_box:box};assert.deepEqual(invalidGeometry(valid),[]);
 assert.ok(invalidGeometry({...valid,nodes:[{id:'A',box:{...box,x:null}}]}).length);
 assert.ok(invalidGeometry({...valid,view_box:{...box,width:-1}}).length);
 assert.ok(invalidGeometry({...valid,edges:[{id:'e',points:[{x:0}]}]}).length);
});

test('new diagram parity gates reject bad pixels and wrong canvas sizes without rescaling',()=>{
 assert.deepEqual(parityProblems('sequence',0.05,box,box),[]);
 assert.ok(parityProblems('sequence',0.050001,box,box).length);
 assert.ok(parityProblems('state',0, {...box,width:101.01},box).length);
 assert.ok(parityProblems('class',NaN,box,box).length);
 assert.ok(parityProblems('entity',-0.1,box,box).length);
});
