#!/usr/bin/env python3
"""Admit the fixed build inputs through Roc's verified unbundler.

This is a transport workaround, not a dependency resolver. Original Roc URLs,
compiler selection, XDG/HOME, and Blueprint's separate artifact store stay intact.
Only raw archives may be reused; every seed verifies and unbundles them afresh.
The admitted inventories and primary-source rationale are recorded in issue #32.
"""

import argparse
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass
from types import MappingProxyType


class AdmissionError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise AdmissionError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


@dataclass(frozen=True)
class Source:
    key: str
    repository: str
    tag: str
    asset_id: int
    content_hash: str
    size: int
    sha256: str
    tar_size: int
    tar_sha256: str
    # Exact regular file inventory: path, content bytes, SHA256. Archive mode is
    # 0644; the official unbundler intentionally creates private 0600 files.
    members: tuple
    role: str = "immutable-source"

    @property
    def archive_name(self):
        return self.content_hash + ".tar.zst"

    @property
    def api_url(self):
        return f"https://api.github.com/repos/{self.repository}/releases/assets/{self.asset_id}"

    @property
    def published_asset_name(self):
        return ("roc-blueprint-core-" if self.key == "core" else "") + self.archive_name

    @property
    def canonical_url(self):
        return f"https://github.com/{self.repository}/releases/download/{self.tag}/{self.published_asset_name}"


_APPROVED = (
    Source(
        'core', 'lukewilliamboswell/roc-blueprint', '0.12.0', 725946981,
        '3mh7nRh7hHcVamEwYFCtd7aMUEoP3cdpAk9gLsZMV17m', 132723,
        'b367d5d91a32c002d09d5309a28ae82c0e978a6cd59ed4eb249e395700a01910',
        531968, '48c76e46db21fe1562fc07e4fc16e457f18f9111dc982dca3bc18bbee9ee7cb9',
        (
            ('main.roc', 313, '017d20c102592c9c502aa46cf3e6e78eb86249cb9f44757eea5f80e2190190c6'),
            ('Activation.roc', 6080, '8c7b68df85f5e0607db71ef653e02efd351e6a6a194e1d96e40fa8e4e53ee117'),
            ('BuildModel.roc', 13239, '03e540330810e54e05f879b8d1af647209983a3b4e2dd2ef57f20e089272bf41'),
            ('CycloneDx.roc', 19960, '334b7ef4d3881142ed1e4c5edd7c4edd3588a0c6a7fae7dc07c8d0023d671ce4'),
            ('JsonData.roc', 17611, 'a1a4cacbb774184ba3573b5fb03519094ede649c0c3704cbbc24d81f269dd656'),
            ('Layout.roc', 2510, '2788742ec5aa05b875c1a717a0362fc03fee4be56a7acc5bc8e4f33cba49cdf3'),
            ('Lock.roc', 31027, '6e6b2f0f93dfb8e88b1f73eaaf442748b980cedd63f008196c03b107ae7cd8b1'),
            ('LockSnapshot.roc', 18687, '08e948136d70d70d2c0ea61378ff4cbbd6300d7dea84b08a414d1e06b05d61d6'),
            ('Lookup.roc', 2391, '876a2cc466ab609ead5849cd65ad3c18f741ab5b643d3be597be5e2dde6749ed'),
            ('Manifest.roc', 9690, '6ab1e0189ce7962c9a0216b29154a33de9af258170edc53eddd035fe2ad962d2'),
            ('Project.roc', 94022, '363b876e8be8d8da43574ae89af53c63940a36ce8d2847212a1cf7165f760a5f'),
            ('Provider.roc', 5774, '4e6af75588f5854c2373a6693ccb5929bd90040068263d4df45475c751578c6c'),
            ('Realise.roc', 60253, 'ae47de85c20ad12366420e99eb5c40b74565607ab11512f4c56463f6a5df8c7d'),
            ('Request.roc', 175, '64c38f6c49e3f993b88c3a736365005624584dc1d2692486b11a21799d7fdb91'),
            ('Sbom.roc', 111185, '13c2f51b8703324e61b38cb8b7aaba205cb54d9d223e1026011936f0728fb123'),
            ('SbomLicenses.roc', 14878, 'ccb1aadbd6d955564c400a0c0ef94e8fc8f6e65781eb172f4cd1182afd6a3975'),
            ('Sexpr.roc', 14985, '73946181e9e2f2e500d359796476d37805a32cebdd4dea99989e61e052cc6515'),
            ('Sidecar.roc', 6882, '5cd13d8a3553005472dda9a001e48a92d0b53a51c7e8fc19140ef12d28b26e44'),
            ('Spdx2.roc', 21038, '0a991a66ef13de35c1487fc9dda9443d4b2e9e788539350fa62c2b6f307161d0'),
            ('Spdx3.roc', 23586, 'a19d011f3f710c75f1050dbbaac203f257fb2f7cc12caa46cee0ce3bf893c3cf'),
            ('Spec.roc', 17235, '4e09cce6645824d4aaee778515c71fcfd9f78ab838d4952018fac4db0c373373'),
            ('Steps.roc', 5449, 'b62dbe60212d6f4edcac103e6b03d441696e811f85167bb41472df1f4e44adec'),
            ('Tree.roc', 3715, 'b56e382a481480325f537e1ff6c086379cd063a986d5be1a368c709bd58536ad'),
            ('Value.roc', 6169, 'a5bb19f95c3ee2af7e598e9b831cce3960de6083ee4d1c21d556087d4ac0df02'),
            ('lock-snapshot-v2.schema.json', 5004, '11c7f5497d0d2cf55a6cfd66288d969ecf61603e18f94d864c16b89ca9587246'),
        ),
    ),
    Source(
        'font', 'lukewilliamboswell/roc-font', '0.1.0-rc2', 674005967,
        'A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5', 4106898,
        '11d50f4fd4758cb85dec5e76abc8045c454410efc346d41ff8d5c6605fc8ef0c',
        6683136, '2415051bdec484ca10048b4d6bec92903468f57c1e5858bfec262001bd025713',
        (
            ('main.roc', 26, 'b9485d62d15ecd36e34de8871aef7ac537f67f79609f41087bb4de2e47fc25dd'),
            ('Bytes.roc', 1004, 'c7109878d38934a26d175a1a9d67041b3b7f9c47c1253e272405b17eb2d550af'),
            ('Face.roc', 35509, '862103703d18b63fd86fdcbe5f25790c65f4cb36f3ba05a6ed6899f51f404840'),
            ('Font.roc', 33685, '0d945bfdbc0ef9bf31053cc39a10c785ed883f5b63c1d12f7f576a408dd9165b'),
            ('LayoutCommon.roc', 9428, '498014ea678b5447889e1117bb881d161c6d4c31c3a742e6491d6551cbf91503'),
            ('LayoutGdef.roc', 8957, '2e7fca56932d80a0a299355f337ffcf0005c29bcebce6d81a773b1244b6d6387'),
            ('LayoutGsub.roc', 131459, '9fe58327f048d5b83e13356914ebc937bd2c4bd3fb34ecadbee6a9ee55cec8e8'),
            ('LayoutKerning.roc', 38830, 'd72456d6402ba48c52ec6f169eda11185ecfedf5358e3dcbca3789a74a008b4d'),
            ('LayoutVar.roc', 98369, '58016cc0bc1404edd235a9332f95806997219db3a954158211bb51cba662b106'),
            ('Sfnt.roc', 4975, 'c654cfdc5e753c499afbaf03373a7213e1ca2076404e7719d1d613db3c51c1aa'),
            ('Shaper.roc', 46338, '10b14653bf80e1e1a3b63513df3d07201a1042a3a57b667fcd51a4338f452820'),
            ('ShaperLanguages.roc', 21664, '612e6bae83ff34fd904ac4dfc7cb6f4b32f3ee99404fbf76e7f5e96427494181'),
            ('ShaperNormalize.roc', 25211, '2df0ff59a2fe940588ef3c2e8e7e43dcc61cb3a91f6cf6bffbf501ea59f7f206'),
            ('ShaperTags.roc', 15958, 'f53662907cb29c6f1d057975a56c7b9fe239ab74d530ff7f86d6d7e2cc595f36'),
            ('ShaperUnicode.roc', 19096, '9868c224b9606aa7826dc022cc1c4f756fd7d501616acab49304b10954982b5d'),
            ('ShaperUnicodeData.roc', 101890, 'f6debc13be15d36486a3115131aadc22383753372ad0f02dbc551713dc48f623'),
            ('Sorted.roc', 2922, '4c493e029eb0a09b2d9c57620f2cdb0ba3635a12886ce242514e3cb589d2549e'),
            ('TableCmap.roc', 52957, '07c1dfb219b29b62c44ad77e2beb0e5f661240353e2847ac34bf77251fcd432f'),
            ('TableGlyf.roc', 3389, 'c7086b13e0dad46381f0663b0fc088415093253341ca801ba45f97ff91b2775a'),
            ('TableGlyfPoints.roc', 21790, 'e96fd92e79379ecdaa8401c8bce600bf182dda1e621b9311bb5ca25354013789'),
            ('TableGvar.roc', 53561, 'afceb022c254c5949d64670f7f81b3856aac8561808734974dc3144b01a80fdd'),
            ('TableHead.roc', 1826, '5b2af6905f3d69ea958b59bd229af26584a797caa7f4b37307cbb6c7278ed8ad'),
            ('TableHhea.roc', 880, '8793b5180a33123d67c3a60366e388d75047266b23283f232b368793cbcb7551'),
            ('TableHmtx.roc', 888, '082c0544c1d4bde70875016219a5f05dcf5acffc7e2f1f72ff1464ad7cc44ae9'),
            ('TableMaxp.roc', 471, '952d6224ab51c320ce3182d356a1c0ae4c333247a1717eb8d9ef1d381883c028'),
            ('TableName.roc', 32105, 'df18e074988cc8c5cfa9730acd7df73d070b49ff6daf60638ac5c1598d8c245a'),
            ('TableOs2.roc', 2036, 'a8700a95613e27f8f421341a58dea1cd54dd264ac102695ccf6b5c015ca3c763'),
            ('TablePost.roc', 23503, '302dddf03224be781239fa804ba1987e0db539dbc79c8cd446c1fe23d19fd1f2'),
            ('TableVar.roc', 59497, 'cc97c672582aab210acdc997c309054df7348a93669b0c898b212c0fed6ccb53'),
            ('fonts/FiraCode-OFL.txt', 4389, '1d41e10031ab125302780a05ec4c91d218e47db0c7e37cf315cce5e608cdc25c'),
            ('fonts/FiraCode-Variable.ttf', 286320, '04149681350f161aca538858b88d17443c586cacca83c165939a13423fe91a26'),
            ('fonts/Inter-OFL.txt', 4380, '262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a'),
            ('fonts/Inter-Variable.ttf', 879708, '4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf'),
            ('fonts/Merriweather-OFL.txt', 4438, '715bd349bfa6116f99e351e1548321dcfa25b91df65502d22ca8d624557697d2'),
            ('fonts/Merriweather-Variable.ttf', 4628080, '22e924e4ea00ef19a5b30dd2c5c32674009badb39bb4611336960eb32ad7a422'),
        ),
    ),
    Source(
        'basic-cli', 'roc-lang/basic-cli', '0.27.0', 720815853,
        '9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g', 23399272,
        '81760dd9d6f31d8a1ef4263357228bdcacc4ef23e6ba624abff02e161724a8af',
        83009024, '49d8cacf21dcd0a141cf0d230b8af76db655849195eec0ac5746bd1e665aadaa',
        (
            ('main.roc', 8367, '52b38e67fbd41669a0dc18512054fc40580b645615083b111106ad687d28cd48'),
            ('Cmd.roc', 42582, 'b2a999b4159e6ff6759ef3d2d96e677fe6a3e06335d9d7f72009df6ce71d0468'),
            ('Duration.roc', 11203, '45802dfb715edb6732db41a543c5d3a4e1beb0fb0d891593f6425eaa3c39ed73'),
            ('Env.roc', 5621, '561e88860835e8c5d85aeb78a5b5886364e359b1bc7642418143a457a1629201'),
            ('File.roc', 13942, '299737a84d82b48dbc8e5f705810e05fd3ae0fd5663de94cd25438f00aa5def4'),
            ('Host.roc', 11509, '1c670d9ad61ae978f029e679306068b841b32105b396341c3a634021636ef877'),
            ('Http.roc', 19751, 'b74d24cb60e36ffbf831118fa9152643efb968e43d6fa9424b176d843b72041c'),
            ('IOErr.roc', 2901, 'a8dfe67982932608e9d2728e3741b35c03fb2ed64109177dbd2ec77c67e3b067'),
            ('InternalDateTime.roc', 5443, 'c61499de6f408304e8489e3fdb766678169cace1c963dbeaf4e1e73699401893'),
            ('InternalHttp.roc', 2675, '3e855ddb5e400bd4bc8a6a085fa94deaf27ecb02f31ded5bc26435fe065ff305'),
            ('InternalSqlite.roc', 838, '8f0eb4b9b852aae0926743218630bbaef756aac26da2898ee1ad1b19f69a47e4'),
            ('InternalUtf16.roc', 6195, 'b76e175195d9b66808dbf984e32637605d701d0285bd770a4eb6d5e458924125'),
            ('LICENSE', 1915, '26285f30ae3d8c53a4dc1db652a8a7b8c7a4a0283946ae3d35774b1c8e543178'),
            ('Locale.roc', 8678, 'b973c0242dc8c803e08955f41db08765a6ccac3adfba94d74fb7a4808a527f9b'),
            ('Monotonic.roc', 1737, '51339808b2041f461847a2c18cb2093bcae6099a42ec2deb431be4239bdc9a44'),
            ('OsStr.roc', 15436, '3d4e079bd61474a1416a8b2cd35dd008bad4ca579ee375cdb11d7befd5bfde6b'),
            ('Path.roc', 37618, '55d68cbbc4331e5edb4938e1417444292638e209e9b831a3d879b127ddbfac64'),
            ('Random.roc', 1050, '277fe19ef33c2d68e11eaa7ede710b949af35ca3d6f690091f87f6010fb0770a'),
            ('Resource.roc', 1036, 'c0b37e548cbcb9614dad3de6593b66024fe2215eb0775491997fb39ee571f7d7'),
            ('Signal.roc', 1193, 'fe25e2b3f953302c08b387b2d75fe676111f3457badf2e7f5c3b8682b4ce15a3'),
            ('Sleep.roc', 2472, 'ed056cea16d7b39a8092387ef210c723088e89264829265724da2923e0605719'),
            ('Sqlite.roc', 36163, 'e772a0c46f73d9b253c4270e219bec6bade92bb9ab7a3d964bad7a8dbd0be2ed'),
            ('Stderr.roc', 2069, '10249ed7d5e5f86656444717500e12fdc886aa95b0aefc6d85b6f1dad555bd0c'),
            ('Stdin.roc', 6013, 'd58e14431ef739f77ef1c53841fd3d462c83f00270b8305149dd19adc3e0437d'),
            ('Stdout.roc', 2095, '7a6a648a7ec8453827becc520a16033dde5818078bbfefeadfb35d36e4a522db'),
            ('System.roc', 1357, '7a98e24829502504a9a83ced9551c2ec29d6ec1e93593613ab5b5423f20c3828'),
            ('THIRD_PARTY_LICENSES.md', 238189, 'cb2cabbcef3214c328822ba67d3ade45e8d72c721073b772dd6ba1fb73ff2d45'),
            ('Tcp.roc', 15843, 'f15dd378d83f9e2e51c5da7991bef26975e6c79de88d24239a5331108bec8bf8'),
            ('Tty.roc', 2994, 'd03332cb5755e43c14a4f07982881b49b527c23f00bcf82ab0d36f05a4a803fe'),
            ('UnixSocket.roc', 14289, '4677f17f03c5f07a00b9d1d0f57859e23622c799fe7187ea5153072489fb82e5'),
            ('Url.roc', 36240, 'f055a3508a37485be1a236b76bd866c675296ff0e21e8869aab9c2e7958ace38'),
            ('Utc.roc', 10557, '7f1a312fa7f0684197a7b275b68951f3e5d571b173f56ca706122b29e4e5c344'),
            ('targets/arm64mac/libhost.a', 12026544, '659adea5b25d588acd2561c8ceaef80f850ae7e6138b9aa993af13f6410a4626'),
            ('targets/arm64musl/crt1.o', 5576, '0245544b81293be7bc86df1a8c0140ce1c0345c6abef11dcb20d0cfebc237ef1'),
            ('targets/arm64musl/libc.a', 2640752, '209b1743f3b0108f5e3f2196dcef9dd40027928c89dad29fafea896772c84878'),
            ('targets/arm64musl/libhost.a', 10991860, '8036ad766272240e73a26f58f045ecb69e1a7fbfdbb0f0dcb2d7052d43fba968'),
            ('targets/arm64musl/libunwind.a', 190856, '7d246ebb58d7c90ea3ee1907afc3e7e8f8dc5b8699173dd0373d9c813fff017d'),
            ('targets/x64mac/libhost.a', 12280752, 'e66f3a791e85949f42dbb21a5a0ffead038afdd6be5f31e173cd7b89af5523f6'),
            ('targets/x64musl/crt1.o', 5040, 'ffb51a69191a69fc34acaec1003fabe245d8841da7036d124d3445718415f9ea'),
            ('targets/x64musl/libc.a', 9137174, '85f5eb2316bc6f86be7bd66008488c7d2eca290942b01ad2e86f02f8b5e8c90f'),
            ('targets/x64musl/libhost.a', 10925096, '30349107a8714f66943989aa35a5b0c1976d8814fddcd822b67f0390be6eafe8'),
            ('targets/x64musl/libunwind.a', 204668, 'e59505f4e8e9bb8e19833e40a56555fc68805ec0cecf4084957e8865520ef7f4'),
            ('targets/x64win/PROVENANCE.json', 370869, '95de46577f6030bce581ce0be131331ce18c05791c84d36bf12d89306cec7d1b'),
            ('targets/x64win/host.lib', 17848844, '1fd90bf9c61e28f099f0e43844cdb521d4767847424c433a9d40634ff5d092af'),
            ('targets/x64win/licenses/basic-cli-UPL-1.0.txt', 1998, '6aee707cfae2fd84132a344c3a4630ff2780f9c543beb55673442e46a81b0103'),
            ('targets/x64win/licenses/cargo/bytes-1.12.1/LICENSE', 1055, '45f522cacecb1023856e46df79ca625dfc550c94910078bd8aec6e02880b3d42'),
            ('targets/x64win/licenses/cargo/cfg-if-1.0.3/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/cfg-if-1.0.3/LICENSE-MIT', 1057, '378f5840b258e2779c39418f3f2d7b2ba96f1c7917dd6be0713f88305dbda397'),
            ('targets/x64win/licenses/cargo/equivalent-1.0.2/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/equivalent-1.0.2/LICENSE-MIT', 1049, '7365cc8878a1d7ce155a58c4ca09c3d7a6be413efa5334a80ea842912b669349'),
            ('targets/x64win/licenses/cargo/fastrand-2.5.0/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/fastrand-2.5.0/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/fnv-1.0.7/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/fnv-1.0.7/LICENSE-MIT', 1056, '65fdb6c76cd61612070c066eec9ecdb30ee74fb27859d0d9af58b9f499fd0c3e'),
            ('targets/x64win/licenses/cargo/futures-0.3.31/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-0.3.31/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/futures-channel-0.3.31/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-channel-0.3.31/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/futures-channel-0.3.31/SOURCE-NOTICES.txt', 4056, '592b6b99c5c6517a2e9f05365a94f5e84f010b706ec97a0c66faf203e81a2d1c'),
            ('targets/x64win/licenses/cargo/futures-core-0.3.32/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-core-0.3.32/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/futures-executor-0.3.31/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-executor-0.3.31/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/futures-io-0.3.34/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-io-0.3.34/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/futures-macro-0.3.31/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-macro-0.3.31/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/futures-sink-0.3.34/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-sink-0.3.34/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/futures-task-0.3.32/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-task-0.3.32/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/futures-util-0.3.31/LICENSE-APACHE', 10874, '275c491d6d1160553c32fd6127061d7f9606c3ea25abfad6ca3f6ed088785427'),
            ('targets/x64win/licenses/cargo/futures-util-0.3.31/LICENSE-MIT', 1094, '6652c868f35dfe5e8ef636810a4e576b9d663f3a17fb0f5613ad73583e1b88fd'),
            ('targets/x64win/licenses/cargo/getrandom-0.2.16/LICENSE-APACHE', 10849, 'aaff376532ea30a0cd5330b9502ad4a4c8bf769c539c87ffe78819d188a18ebf'),
            ('targets/x64win/licenses/cargo/getrandom-0.2.16/LICENSE-MIT', 1130, '42fa16951ce7f24b5a467a40e5b449a1d41e662f97ca779864f053f39e097737'),
            ('targets/x64win/licenses/cargo/getrandom-0.3.4/LICENSE-APACHE', 10849, 'aaff376532ea30a0cd5330b9502ad4a4c8bf769c539c87ffe78819d188a18ebf'),
            ('targets/x64win/licenses/cargo/getrandom-0.3.4/LICENSE-MIT', 1130, '29e9fe5074bd27e0e5d5d110394fbbcd841baee2651a3c4b4560a632702cede4'),
            ('targets/x64win/licenses/cargo/hashbrown-0.17.1/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/hashbrown-0.17.1/LICENSE-MIT', 1060, 'ff8f68cb076caf8cefe7a6430d4ac086ce6af2ca8ce2c4e5a2004d4552ef52a2'),
            ('targets/x64win/licenses/cargo/http-1.3.1/LICENSE-APACHE', 10835, '8bb1b50b0e5c9399ae33bd35fab2769010fa6c14e8860c729a52295d84896b7a'),
            ('targets/x64win/licenses/cargo/http-1.3.1/LICENSE-MIT', 1059, 'dc91f8200e4b2a1f9261035d4c18c33c246911a6c0f7b543d75347e61b249cff'),
            ('targets/x64win/licenses/cargo/http-body-1.0.1/LICENSE', 1083, 'cddabf8adc6ccd6c3e68f5d71eac9fae3094116623cf23a46af0a5fd6b8ee813'),
            ('targets/x64win/licenses/cargo/http-body-util-0.1.3/LICENSE', 1083, 'b843fb7430efdf9732c834b6814beda44fccf3f0ddf7c9e030b39da17f6b159c'),
            ('targets/x64win/licenses/cargo/httparse-1.10.1/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/httparse-1.10.1/LICENSE-MIT', 1063, '391a5396cec6230bfabd4ef4eb2350eb895bc5efce377a2218f5702ed020d3e3'),
            ('targets/x64win/licenses/cargo/hyper-1.6.0/LICENSE', 1062, '8f2eee700f56dd8b381d92dc5b136befe09f90e186f2c1c8414a70c4c7534550'),
            ('targets/x64win/licenses/cargo/hyper-rustls-0.27.6/LICENSE', 292, 'd1ef92123fc699442e1e8d971fe84921947efc8d9a1249ab037f1e661a972a6d'),
            ('targets/x64win/licenses/cargo/hyper-rustls-0.27.6/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/hyper-rustls-0.27.6/LICENSE-ISC', 775, '7cfafc877eccc46c0e346ccbaa5c51bb6b894d2b818e617d970211e232785ad4'),
            ('targets/x64win/licenses/cargo/hyper-rustls-0.27.6/LICENSE-MIT', 1082, '709e3175b4212f7b13aa93971c9f62ff8c69ec45ad8c6532a7e0c41d7a7d6f8c'),
            ('targets/x64win/licenses/cargo/hyper-util-0.1.12/LICENSE', 1062, '9e0a97848ea543aef745c98e84fde696a9a3e0735538f6daefdd3cb1942effc1'),
            ('targets/x64win/licenses/cargo/indexmap-2.14.2/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/indexmap-2.14.2/LICENSE-MIT', 1049, 'ecc269ef87fd38a1d98e30bfac9ba964a9dbd9315c3770fed98d4d7cb5882055'),
            ('targets/x64win/licenses/cargo/itoa-1.0.15/LICENSE-APACHE', 9723, '62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a'),
            ('targets/x64win/licenses/cargo/itoa-1.0.15/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/libc-0.2.180/LICENSE-APACHE', 9723, '62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a'),
            ('targets/x64win/licenses/cargo/libc-0.2.180/LICENSE-MIT', 1076, 'a8d47ff51ca256f56a8932dba07660672dbfe3004257ca8de708aac1415937a1'),
            ('targets/x64win/licenses/cargo/libsqlite3-sys-0.33.0/LICENSE', 1067, 'c10c1f27337546471e5f7e4e97fdd398b35b9d4e126115dcd22de8d8e65abf6f'),
            ('targets/x64win/licenses/cargo/libsqlite3-sys-0.33.0/SOURCE-NOTICES.txt', 29391, 'e0bc6bd4599ccb5ba52bb49cd5d3f194daf7cedb606cbde0af2015fdacfbc5d6'),
            ('targets/x64win/licenses/cargo/libsqlite3-sys-0.33.0/sqlcipher/LICENSE', 1467, 'ea4fcb309f14a22065e1ea45362d494d320012249ed865fe9c7c0946db754131'),
            ('targets/x64win/licenses/cargo/memchr-2.7.4/COPYING', 126, '01c266bced4a434da0051174d6bee16a4c82cf634e2679b6155d40d75012390f'),
            ('targets/x64win/licenses/cargo/memchr-2.7.4/LICENSE-MIT', 1081, '0f96a83840e146e43c0ec96a22ec1f392e0680e6c1226e6f3ba87e0740af850f'),
            ('targets/x64win/licenses/cargo/memchr-2.7.4/UNLICENSE', 1211, '7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c'),
            ('targets/x64win/licenses/cargo/mio-1.0.4/LICENSE', 1082, '07919255c7e04793d8ea760d6c2ce32d19f9ff02bdbdde3ce90b1e1880929a9b'),
            ('targets/x64win/licenses/cargo/once_cell-1.21.3/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/once_cell-1.21.3/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/pin-project-lite-0.2.16/LICENSE-APACHE', 10174, '0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594'),
            ('targets/x64win/licenses/cargo/pin-project-lite-0.2.16/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/pin-utils-0.1.0/LICENSE-APACHE', 10841, 'a4db788775cb25f2da419a7ccd3f1f89c3d2cfa8748fb25257596b88183b4c77'),
            ('targets/x64win/licenses/cargo/pin-utils-0.1.0/LICENSE-MIT', 1065, '28802412d2bfbafe432b305634413b41a984d30fba0df41d30aa2c8a2077c5b1'),
            ('targets/x64win/licenses/cargo/proc-macro2-1.0.101/LICENSE-APACHE', 9723, '62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a'),
            ('targets/x64win/licenses/cargo/proc-macro2-1.0.101/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/process-wrap-10.0.0/LICENSE-APACHE', 9723, '62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a'),
            ('targets/x64win/licenses/cargo/process-wrap-10.0.0/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/quote-1.0.41/LICENSE-APACHE', 9723, '62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a'),
            ('targets/x64win/licenses/cargo/quote-1.0.41/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/ring-0.17.14/LICENSE', 499, 'b3d734001a94efff3579978d953391aa7115f877657d25eb54037a43875d078a'),
            ('targets/x64win/licenses/cargo/ring-0.17.14/LICENSE-BoringSSL', 14870, '005fc765ddc5115da796cca915baa9557abae13ff35e0a47c47affc56f6c414d'),
            ('targets/x64win/licenses/cargo/ring-0.17.14/LICENSE-other-bits', 731, 'f025ccfb7dfb6bdfedc75ca0f67acc69e6fb4998143d834f7c2f38a29989680f'),
            ('targets/x64win/licenses/cargo/ring-0.17.14/SOURCE-NOTICES.txt', 593549, '7c2647316b06e04dcd3fc536021f641a80dbd3d2b7b61b646034c1657235c656'),
            ('targets/x64win/licenses/cargo/ring-0.17.14/src/polyfill/once_cell/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/ring-0.17.14/src/polyfill/once_cell/LICENSE-MIT', 1022, '6ee2ed6c77710de911761acd5fc1ad1da00f476beb1a7ef27e78c2d1858deafc'),
            ('targets/x64win/licenses/cargo/ring-0.17.14/third_party/fiat/LICENSE', 638, '9eacbcb81be660840c714a560a9d65ba07913db98dd4baf969f78dd499fdd60f'),
            ('targets/x64win/licenses/cargo/roc_host-0.27.0/LICENSE', 1932, '6a04bc7629df467cad511bed637e48d2d5b12d456b7d39a1b6508474d4875a82'),
            ('targets/x64win/licenses/cargo/rustls-0.23.46/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/rustls-0.23.46/LICENSE-ISC', 775, '7cfafc877eccc46c0e346ccbaa5c51bb6b894d2b818e617d970211e232785ad4'),
            ('targets/x64win/licenses/cargo/rustls-0.23.46/LICENSE-MIT', 1082, '709e3175b4212f7b13aa93971c9f62ff8c69ec45ad8c6532a7e0c41d7a7d6f8c'),
            ('targets/x64win/licenses/cargo/rustls-pki-types-1.12.0/LICENSE-APACHE', 10835, '45fd05c4865e7c350b98ad7ac50e1b15462d49af4a91e9b0c9dd933dc9a69742'),
            ('targets/x64win/licenses/cargo/rustls-pki-types-1.12.0/LICENSE-MIT', 1080, '9117d922e667125508dde62b02c1f57ed22f5ad21eb536aa2e2d99e1c796e639'),
            ('targets/x64win/licenses/cargo/rustls-webpki-0.103.15/LICENSE', 916, '5b698ca13897be3afdb7174256fa1574f8c6892b8bea1a66dd6469d3fe27885a'),
            ('targets/x64win/licenses/cargo/rustls-webpki-0.103.15/SOURCE-NOTICES.txt', 58080, 'e6fc87f4e7dc84db526afdfd5c0b19c0f2899d928f000dd6df4c73bd4aaa8cd5'),
            ('targets/x64win/licenses/cargo/same-file-1.0.6/COPYING', 126, '01c266bced4a434da0051174d6bee16a4c82cf634e2679b6155d40d75012390f'),
            ('targets/x64win/licenses/cargo/same-file-1.0.6/LICENSE-MIT', 1081, 'cb3c929a05e6cbc9de9ab06a4c57eeb60ca8c724bef6c138c87d3a577e27aa14'),
            ('targets/x64win/licenses/cargo/same-file-1.0.6/UNLICENSE', 1211, '7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c'),
            ('targets/x64win/licenses/cargo/slab-0.4.12/LICENSE', 1055, '8ce0830173fdac609dfb4ea603fdc002c2f4af0dc9b1a005653f5da9cf534b18'),
            ('targets/x64win/licenses/cargo/smallvec-1.15.1/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/smallvec-1.15.1/LICENSE-MIT', 1072, '0b28172679e0009b655da42797c03fd163a3379d5cfa67ba1f1655e974a2a1a9'),
            ('targets/x64win/licenses/cargo/socket2-0.5.10/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/socket2-0.5.10/LICENSE-MIT', 1057, '378f5840b258e2779c39418f3f2d7b2ba96f1c7917dd6be0713f88305dbda397'),
            ('targets/x64win/licenses/cargo/socket2-0.5.10/SOURCE-NOTICES.txt', 15418, 'ef5d61211ec492708cf8835b55f846bc05b90ed61653f6f9c44361145523f693'),
            ('targets/x64win/licenses/cargo/subtle-2.6.1/LICENSE', 1582, 'd1fc1bc0d155df60b2e7705b6b2ae02a05c96f948e1cec6e2fb86360b09f346b'),
            ('targets/x64win/licenses/cargo/subtle-2.6.1/SOURCE-NOTICES.txt', 4444, 'b8ed74b347c25415d603cf12ec615ecfcd41da6bb5c0812bb85f9d93cabd461c'),
            ('targets/x64win/licenses/cargo/syn-2.0.106/LICENSE-APACHE', 9723, '62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a'),
            ('targets/x64win/licenses/cargo/syn-2.0.106/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/sys-locale-0.3.2/LICENSE-APACHE', 11357, 'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4'),
            ('targets/x64win/licenses/cargo/sys-locale-0.3.2/LICENSE-MIT', 1066, '5cc390ab5e5e6507f467368cbab1297552d64bfd863f4b496c7928508bcfefd8'),
            ('targets/x64win/licenses/cargo/tempfile-3.23.0/LICENSE-APACHE', 10847, 'a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2'),
            ('targets/x64win/licenses/cargo/tempfile-3.23.0/LICENSE-MIT', 1056, '8b427f5bc501764575e52ba4f9d95673cf8f6d80a86d0d06599852e1a9a20a36'),
            ('targets/x64win/licenses/cargo/tempfile-3.23.0/SOURCE-NOTICES.txt', 5750, '335bc1ce05c1ff68163abcec7348e7c4c29234392fb76e8e71ca2cce83696af2'),
            ('targets/x64win/licenses/cargo/tokio-1.45.0/LICENSE', 1070, '253cd04c6714889df2d32f3f64d669179a1c95c76ac43c40882c52eb06bc3552'),
            ('targets/x64win/licenses/cargo/tokio-macros-2.5.0/LICENSE', 1102, '0b83dc40cba89b9922bb84b0a9c7d2768ce37c1d7e138b7424fd4549915778c9'),
            ('targets/x64win/licenses/cargo/tokio-rustls-0.26.4/LICENSE-APACHE', 10832, 'cc117d90b498b32b11a886f279b359da16a73c3b01efbb2f5cc004b20262334e'),
            ('targets/x64win/licenses/cargo/tokio-rustls-0.26.4/LICENSE-MIT', 1056, 'e20fa2b8e0a2565f24a792b94b4bf4b6c2b9d36f781d8a9516e218a036e6677a'),
            ('targets/x64win/licenses/cargo/tower-service-0.3.3/LICENSE', 1062, '4249c8e6c5ebb85f97c77e6457c6fafc1066406eb8f1ef61e796fbdc5ff18482'),
            ('targets/x64win/licenses/cargo/tracing-0.1.41/LICENSE', 1062, '898b1ae9821e98daf8964c8d6c7f61641f5f5aa78ad500020771c0939ee0dea1'),
            ('targets/x64win/licenses/cargo/tracing-attributes-0.1.31/LICENSE', 1062, '898b1ae9821e98daf8964c8d6c7f61641f5f5aa78ad500020771c0939ee0dea1'),
            ('targets/x64win/licenses/cargo/tracing-core-0.1.34/LICENSE', 1062, '898b1ae9821e98daf8964c8d6c7f61641f5f5aa78ad500020771c0939ee0dea1'),
            ('targets/x64win/licenses/cargo/tracing-core-0.1.34/src/spin/LICENSE', 1085, '58545fed1565e42d687aecec6897d35c6d37ccb71479a137c0deb2203e125c79'),
            ('targets/x64win/licenses/cargo/try-lock-0.2.5/LICENSE', 1096, 'c816a0749cdc6bf062a5111c159723de51b2bfac66a1dac2655abd9e6b1583eb'),
            ('targets/x64win/licenses/cargo/unicode-ident-1.0.19/LICENSE-APACHE', 9723, '62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a'),
            ('targets/x64win/licenses/cargo/unicode-ident-1.0.19/LICENSE-MIT', 1023, '23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3'),
            ('targets/x64win/licenses/cargo/unicode-ident-1.0.19/LICENSE-UNICODE', 1995, 'f7db81051789b729fea528a63ec4c938fdcb93d9d61d97dc8cc2e9df6d47f2a1'),
            ('targets/x64win/licenses/cargo/untrusted-0.9.0/LICENSE.txt', 769, '7abd9b6960dcf7d4d0a48606a5b71bfe37d472db68d70637f3a58a56785f1621'),
            ('targets/x64win/licenses/cargo/untrusted-0.9.0/SOURCE-NOTICES.txt', 15505, 'd470cd2efb3ee6e22f1560a3272853a79ffe89220b0aba5eac44c3272734f018'),
            ('targets/x64win/licenses/cargo/want-0.3.1/LICENSE', 1063, 'a65f5d0a945d267751344c95665945b90c030ea107faf5c85d518929886187da'),
            ('targets/x64win/licenses/cargo/webpki-roots-1.0.8/LICENSE', 2371, 'e271993808fec50ab29350b39539cdec611a9103f827e0aa26d61da70e2d33f8'),
            ('targets/x64win/licenses/cargo/winapi-util-0.1.11/COPYING', 126, '01c266bced4a434da0051174d6bee16a4c82cf634e2679b6155d40d75012390f'),
            ('targets/x64win/licenses/cargo/winapi-util-0.1.11/LICENSE-MIT', 1081, 'cb3c929a05e6cbc9de9ab06a4c57eeb60ca8c724bef6c138c87d3a577e27aa14'),
            ('targets/x64win/licenses/cargo/winapi-util-0.1.11/UNLICENSE', 1211, '7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c'),
            ('targets/x64win/licenses/cargo/windows-0.62.2/SOURCE-NOTICES.txt', 5860, '8d281628c155b539fa499ec7a2073c93d762dd105dcc3c01836d0a9d510023e9'),
            ('targets/x64win/licenses/cargo/windows-0.62.2/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-0.62.2/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-collections-0.3.2/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-collections-0.3.2/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-core-0.62.2/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-core-0.62.2/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-future-0.3.2/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-future-0.3.2/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-implement-0.60.2/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-implement-0.60.2/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-interface-0.59.3/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-interface-0.59.3/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-link-0.2.1/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-link-0.2.1/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-numerics-0.3.1/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-numerics-0.3.1/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-result-0.4.1/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-result-0.4.1/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-strings-0.5.1/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-strings-0.5.1/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-sys-0.52.0/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-sys-0.52.0/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-sys-0.59.0/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-sys-0.59.0/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-targets-0.52.6/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-targets-0.52.6/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows-threading-0.2.1/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows-threading-0.2.1/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/windows_x86_64_msvc-0.52.6/license-apache-2.0', 11351, 'c16f8dcf1a368b83be78d826ea23de4079fe1b4469a0ab9ee20563f37ff3d44b'),
            ('targets/x64win/licenses/cargo/windows_x86_64_msvc-0.52.6/license-mit', 1141, 'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'),
            ('targets/x64win/licenses/cargo/zeroize-1.8.2/LICENSE-APACHE', 11358, 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'),
            ('targets/x64win/licenses/cargo/zeroize-1.8.2/LICENSE-MIT', 1095, '0b04ee3ce0021a922f43f37a17fee09a5a1ee6d1f4e149d5bf75b72395a49c72'),
            ('targets/x64win/licenses/mingw-w64-ZPL-2.1.txt', 2326, '99a69660981156c21336fdb5661f89341b013c94e4bf9e1c7467b4745718397f'),
            ('targets/x64win/licenses/roc-UPL-1.0.txt', 1880, 'a71f5f17762cc8ac7a5435fe9810e029dc937d379d216fa7630a2775d42eb833'),
            ('targets/x64win/licenses/rust/COPYRIGHT-library.html', 279302, '0a65bb747c49c7bb816cbc7188319bd6e4e8d08091c1190b8a3c0971c47968ed'),
            ('targets/x64win/licenses/zig-MIT.txt', 1080, '5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177'),
            ('targets/x64win/windows_support.lib', 3919390, '75ee8c92932370cc90845586ed4571599ff5185a49b8b6eac8ca87a34b034c64'),
        ),
        'immutable-platform',
    ),
    Source(
        'legacy-http', 'roc-lang/http', '1.0.0', 467808634,
        '6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS', 1830,
        'e9efaa950e72f6f76cdf6eaf00424572fa69b04ba612732357ac0453678f02b4',
        10752, '6c1c34fef40982c82b1af7700bca8bd0eed42309d58d47d42e8fa1d9081aca11',
        (
            ('main.roc', 61, '03c462daa3a252e6a5acc4bf1b9d1b3df7ae33b1d58d3bbad5bab128003043d4'),
            ('Method.roc', 990, '063c6f5c01e6e0807237b2a6856db25e093ade9eb7e8374f887266ed4974c2b1'),
            ('Request.roc', 2665, '52a99de37d07683b7e1826b57321533166f535d8c9f4ed80072d1172c4d9fa56'),
            ('Response.roc', 1942, 'a1bf7cdc02d8d1b0d839e3eb875d7ed1be1641a9460c46c9ad3b3467c84744c0'),
            ('Header.roc', 333, '3fd770687e99c16ec189a8b31965a0a508cadfb3bcd9b1a729cd9885dcb86482'),
        ),
        'legacy-transitive',
    ),
)

SOURCES = MappingProxyType({source.key: source for source in _APPROVED})


def checked_source(source):
    require(isinstance(source, Source) and source in _APPROVED,
            "source descriptor is not one of the fixed admitted inputs")
    return source


def token_free_environment(environment=None):
    # No auth discovery, curlrc, netrc, gh config or tokens are used. Keep the
    # supplied compiler/cache environment, including XDG, HOME and RA_COMPILER.
    source = os.environ if environment is None else environment
    return {key: value for key, value in source.items()
            if not key.startswith(("GH_", "GITHUB_")) and key != "GH_TOKEN"}


def safe_diagnostic(data, environment=None):
    environment = os.environ if environment is None else environment
    text = data.decode(errors="replace")
    for key, value in environment.items():
        if value and key.startswith(("GH_", "GITHUB_")) and any(
                marker in key for marker in ("TOKEN", "SECRET", "PASSWORD", "CREDENTIAL")):
            text = text.replace(value, "[REDACTED]")
    return json.dumps(text[:2048])


def run_bounded(command, maximum, seconds=60, cwd=None, environment=None):
    """Bound both streams and the whole process group, including pipe holders."""
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=token_free_environment(environment), cwd=cwd,
                               start_new_session=True)
    selector = selectors.DefaultSelector()
    streams = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + seconds
    try:
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        while selector.get_map():
            remaining = deadline - time.monotonic()
            require(remaining > 0, "child process deadline exceeded")
            for key, _ in selector.select(remaining):
                limit = maximum if key.data == "stdout" else 8192
                chunk = os.read(key.fileobj.fileno(), min(65536, limit - len(streams[key.data]) + 1))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                streams[key.data].extend(chunk)
                require(len(streams[key.data]) <= limit, f"child {key.data} bound exceeded")
        try:
            process.wait(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as error:
            raise AdmissionError("child process deadline exceeded") from error
        require(process.returncode == 0,
                f"child process failed: reason=exit code={process.returncode} "
                f"stderr={safe_diagnostic(bytes(streams['stderr']), environment)}")
        return bytes(streams["stdout"])
    finally:
        # Kill lingering descendants even if their parent already exited.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        selector.close()
        process.stdout.close()
        process.stderr.close()


_DARWIN_ROOT_ALIASES = ((Path("/var"), Path("/private/var")),
                        (Path("/tmp"), Path("/private/tmp")))


def physical_system_root(path):
    # macOS creates temporary roots through these two system aliases. Map only
    # their leading component, only after proving the exact system link target.
    # No caller-selected link or nested alias is resolved here.
    if sys.platform == "darwin":
        for alias, physical in _DARWIN_ROOT_ALIASES:
            if path == alias or alias in path.parents:
                if alias.is_symlink():
                    target = Path(os.readlink(alias))
                    if not target.is_absolute():
                        target = alias.parent / target
                    require(target == physical, "unexpected macOS system alias target")
                    return physical / path.relative_to(alias)
    return path


def safe_directory(path):
    """Create missing directories, refusing symlinks at every component."""
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "directory must be an absolute canonical path")
    path = physical_system_root(path)
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        require(stat.S_ISDIR(current.lstat().st_mode), "directory component is a symlink or non-directory")
    return path


def absent(path):
    require(not os.path.lexists(path), f"refusing existing source slot or sidecar: {path.name}")


def atomic_insert(source, destination):
    """Rename without replacing even an empty racing destination directory."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        rename = library.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1)  # RENAME_NOREPLACE
    elif sys.platform == "darwin" and hasattr(library, "renamex_np"):
        rename = library.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(os.fsencode(source), os.fsencode(destination), 4)  # RENAME_EXCL
    else:
        raise AdmissionError("platform lacks a supported no-replace atomic rename")
    if result:
        raise AdmissionError(f"atomic source insertion failed (errno {ctypes.get_errno()})")


def verified_raw(path, source):
    checked_source(source)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise AdmissionError("raw archive is missing, unsafe or unreadable") from error
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "raw archive must be one regular file")
        require(info.st_size == source.size, "raw archive size mismatch")
        data = stream.read(source.size + 1)
    require(len(data) == source.size and sha(data) == source.sha256, "raw archive digest/size mismatch")
    return data


def prepare(source, directory):
    checked_source(source)
    directory = safe_directory(directory)
    if source.role == "legacy-transitive":
        verify_legacy_parent(directory)
    destination = directory / source.archive_name
    if os.path.lexists(destination):
        verified_raw(destination, source)
        return destination
    # --disable must be first: neither curlrc nor netrc nor auth environment is
    # consulted. Both the URL and byte bounds come only from fixed descriptors.
    command = ["curl", "--disable", "--no-netrc", "--fail", "--silent", "--show-error",
               "--location", "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "3",
               "--connect-timeout", "10", "--max-time", "60", "--max-filesize", str(source.size),
               "--header", "Accept: application/octet-stream", source.api_url]
    data = run_bounded(command, source.size)
    require(len(data) == source.size and sha(data) == source.sha256, "download digest/size mismatch")
    with tempfile.TemporaryDirectory(prefix=".source-download-", dir=directory) as temporary:
        pending = Path(temporary) / source.archive_name
        with pending.open("xb") as stream:
            os.chmod(pending, 0o600)
            stream.write(data)
        atomic_insert(pending, destination)
    return destination


def inspect_tar(data, members):
    """Inspect data only; extraction is exclusively the trusted Roc command."""
    expected = {name: (size, digest) for name, size, digest in members}
    require(len(expected) == len(members), "duplicate admitted inventory path")
    observed = set()
    total = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
            for member in archive:
                name = member.name
                require(name and not name.startswith("/") and "\\" not in name
                        and str(PurePosixPath(name)) == name and ".." not in PurePosixPath(name).parts,
                        "unsafe archive member path")
                require(member.isreg() and member.type in (tarfile.REGTYPE, tarfile.AREGTYPE)
                        and not member.linkname and not member.pax_headers, "archive member is not a plain regular file")
                require(member.mode == 0o644, "archive member mode mismatch")
                require(name not in observed, "duplicate archive path")
                require(name in expected and len(observed) < len(expected), "unexpected archive member")
                size, digest = expected[name]
                require(member.size == size, "archive member size mismatch")
                stream = archive.extractfile(member)
                require(stream is not None, "missing archive member data")
                with stream:
                    payload = stream.read(size + 1)
                require(len(payload) == size and sha(payload) == digest, "archive member digest mismatch")
                observed.add(name)
                total += size
    except (tarfile.TarError, OSError, ValueError) as error:
        raise AdmissionError("invalid source tar") from error
    require(observed == set(expected), "missing archive member")
    return {"file_count": len(observed), "content_bytes": total}


def expanded_tar(path, source):
    checked_source(source)
    # The staged raw bytes were already checked before this decompression; do
    # not ask zstd to trust its frame's advertised output size or memory usage.
    data = run_bounded(["zstd", "--decompress", "--stdout", "--memory=64MB", str(path)],
                       source.tar_size, seconds=30)
    require(len(data) == source.tar_size and sha(data) == source.tar_sha256, "expanded tar digest/size mismatch")
    return data


def verify_archive(path, source):
    return inspect_tar(expanded_tar(path, source), source.members)


# This legacy material is authorized by the measured immutable platform parent,
# not by HTTP's mutable release metadata. Neither tuple may be overridden.
_BASIC_CLI_MAIN_SHA256 = "52b38e67fbd41669a0dc18512054fc40580b645615083b111106ad687d28cd48"
_HTTP_EDGE = b'http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",'
_BASIC_CLI_PACKAGES_BLOCK = b'\tpackages {\n\t\t# HTTP data types (Method, Request, Response) come from the shared\n\t\t# roc-lang/http package so apps and other packages using it see the same\n\t\t# nominal types. The platform supplies only the effectful `Http.send!`.\n\t\thttp: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",\n\t}'


def check_legacy_parent_header(main):
    require(sha(main) == _BASIC_CLI_MAIN_SHA256, "legacy input parent member digest mismatch")
    require(main.count(b"\tpackages {\n") == 1
            and main.count(_BASIC_CLI_PACKAGES_BLOCK) == 1 and main.count(_HTTP_EDGE) == 1,
            "legacy input requires the exact sole admitted parent edge")


def verify_legacy_parent(raw_directory):
    parent = SOURCES["basic-cli"]
    # Revalidate RAW bytes and full inventory each time. A previously restored
    # source tree, sidecar, receipt or mutable upstream metadata cannot authorize
    # the legacy child. prepare(parent) has no legacy role and cannot recurse.
    archive = prepare(parent, raw_directory)
    raw = verified_raw(archive, parent)
    with tempfile.TemporaryDirectory(prefix=".parent-edge-", dir=raw_directory) as temporary:
        staged = Path(temporary) / parent.archive_name
        with staged.open("xb") as stream:
            os.chmod(staged, 0o600)
            stream.write(raw)
        data = expanded_tar(staged, parent)
        inspect_tar(data, parent.members)
        main_size = next(size for name, size, _ in parent.members if name == "main.roc")
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as contents:
            with contents.extractfile("main.roc") as stream:
                main = stream.read(main_size + 1)
        check_legacy_parent_header(main)
    return {"source": parent.key, "sha256": parent.sha256,
            "main_sha256": _BASIC_CLI_MAIN_SHA256, "edge": _HTTP_EDGE.decode()}


def cache_root(explicit=None, environment=None):
    environment = os.environ if environment is None else environment
    if explicit is not None:
        selected = explicit
    elif "XDG_CACHE_HOME" in environment:
        selected = environment["XDG_CACHE_HOME"]
        require(bool(selected), "XDG_CACHE_HOME is empty")
    else:
        require(bool(environment.get("HOME")), "HOME is required without XDG_CACHE_HOME")
        selected = str(Path(environment["HOME"]) / ".cache")
    root = Path(selected)
    require(root.is_absolute() and ".." not in root.parts, "cache root must be absolute")
    return root


def compiler_identity(environment=None):
    environment = os.environ if environment is None else environment
    selected = environment.get("RA_COMPILER")
    if selected is None:
        selected = shutil.which("roc", path=environment.get("PATH"))
    require(bool(selected), "trusted Roc compiler is unavailable")
    path = Path(selected).resolve(strict=True)
    require(path.is_file() and os.access(path, os.X_OK), "compiler must be an executable file")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    version = run_bounded([str(path), "version"], 4096, seconds=30, environment=environment).decode().strip()
    require(bool(version), "compiler version is empty")
    return {"path": str(path), "sha256": digest.hexdigest(), "version": version}


def verify_tree(root, members):
    expected = {name: (size, digest) for name, size, digest in members}
    directories = {""}
    for name in expected:
        parent = PurePosixPath(name).parent
        while str(parent) != ".":
            directories.add(str(parent))
            parent = parent.parent
    require(stat.S_ISDIR(root.lstat().st_mode) and stat.S_IMODE(root.lstat().st_mode) == 0o700,
            "extracted root is unsafe")
    observed = set()
    observed_directories = {""}
    for directory, child_directories, files in os.walk(root, followlinks=False):
        for name in child_directories:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            require(stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700
                    and relative in directories, "unsafe or unexpected extracted directory")
            observed_directories.add(relative)
        for name in files:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600,
                    "unsafe extracted file type or mode")
            require(relative in expected and relative not in observed, "unexpected extracted file")
            size, digest = expected[relative]
            require(info.st_size == size, "extracted file size mismatch")
            with path.open("rb") as stream:
                data = stream.read(size + 1)
            require(len(data) == size and sha(data) == digest, "extracted file digest mismatch")
            observed.add(relative)
    require(observed == set(expected) and observed_directories == directories, "incomplete extracted tree")


def seed(source, raw_directory=None, explicit_cache_root=None):
    checked_source(source)
    packages = safe_directory(cache_root(explicit_cache_root) / "roc" / "packages")
    destination = packages / source.content_hash
    sidecar = packages / (source.content_hash + ".deps")
    absent(destination)
    absent(sidecar)
    compiler = compiler_identity()
    with tempfile.TemporaryDirectory(prefix=".source-admission-", dir=packages) as temporary:
        stage = Path(temporary)
        if raw_directory is None:
            raw_directory = os.environ.get("GRAPH_RELEASE_SOURCES_DIR")
        if raw_directory is None:
            raw_directory = stage / "raw"
        raw_path = prepare(source, raw_directory)
        raw = verified_raw(raw_path, source)  # Revalidate bytes on EVERY use.
        archive = stage / source.archive_name
        with archive.open("xb") as stream:
            os.chmod(archive, 0o600)
            stream.write(raw)
        inventory = verify_archive(archive, source)
        run_bounded([compiler["path"], "unbundle", source.archive_name], 8192,
                    seconds=60, cwd=stage)
        tree = stage / source.content_hash
        # The CLI creates its top-level output using the caller umask. Tighten
        # that one directory only; files/implicit directories must already have
        # the official unbundler's private modes, verified below.
        require(stat.S_ISDIR(tree.lstat().st_mode), "unbundler output is not a directory")
        tree.chmod(0o700)
        permitted = {source.archive_name, source.content_hash}
        if Path(raw_directory) == stage / "raw":
            permitted.add("raw")
        require({entry.name for entry in stage.iterdir()} == permitted, "unexpected unbundler output or sidecar")
        verify_tree(tree, source.members)
        absent(destination)
        absent(sidecar)
        atomic_insert(tree, destination)
    return {"source": source.key, "asset_id": source.asset_id, "sha256": source.sha256,
            "repository": source.repository, "tag": source.tag, "canonical_url": source.canonical_url,
            "published_asset_name": source.published_asset_name,
            "size": source.size, "content_hash": source.content_hash, "tar_bytes": source.tar_size,
            **inventory, "compiler": compiler, "package_directory": str(destination),
            "sidecar_created": False, "authorization": source.role,
            "upstream_release_immutable": source.role != "legacy-transitive",
            **({"parent_source": "basic-cli", "parent_main_sha256": _BASIC_CLI_MAIN_SHA256,
                "parent_edge_revalidated": True} if source.role == "legacy-transitive" else {})}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "seed"))
    parser.add_argument("--source", choices=tuple(SOURCES), action="append", required=True)
    parser.add_argument("--raw-dir", type=Path)
    parser.add_argument("--cache-root", type=Path, help="explicit fresh XDG root (seed only)")
    args = parser.parse_args(argv)
    require(len(set(args.source)) == len(args.source), "duplicate source selection")
    raw_directory = args.raw_dir or os.environ.get("GRAPH_RELEASE_SOURCES_DIR")
    if args.operation == "prepare":
        require(args.cache_root is None and raw_directory is not None, "prepare requires --raw-dir and no --cache-root")
        receipts = [{"source": name, "archive": str(prepare(SOURCES[name], raw_directory)),
                     "sha256": SOURCES[name].sha256, "size": SOURCES[name].size,
                     "asset_id": SOURCES[name].asset_id, "canonical_url": SOURCES[name].canonical_url,
                     "published_asset_name": SOURCES[name].published_asset_name} for name in args.source]
    elif raw_directory is None:
        # Share only raw bytes within this invocation. Each source admission
        # still rehashes and freshly unbundles into its own private cache stage.
        with tempfile.TemporaryDirectory(prefix="graph-release-sources-") as temporary:
            receipts = [seed(SOURCES[name], Path(temporary), args.cache_root) for name in args.source]
    else:
        receipts = [seed(SOURCES[name], raw_directory, args.cache_root) for name in args.source]
    print(json.dumps({"admitted_sources": receipts}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except AdmissionError as error:
        print(f"source admission failed: {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, UnicodeError):
        # OS exceptions may include caller paths or external data. Report the
        # refusal without reflecting those strings into CI logs.
        print("source admission failed: unsafe or unavailable input", file=sys.stderr)
        sys.exit(1)
