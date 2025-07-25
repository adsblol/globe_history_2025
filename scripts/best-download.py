#!/usr/bin/env python3

# This script:
import os
import tempfile
import requests
import aiohttp
import asyncio

import pathlib
async def process_link(L):
    print(f"{L}: Processing link")
    links = L.split(",")
    date = links[0].split("/")[-1].split("-")[0].replace("v","").replace(".","-")
    date_path = date.replace("-","/")
    path = pathlib.Path(__file__).parent.absolute() / date_path
    done = os.path.exists(f"{path}/.done")
    if done:
        print(f"{L}: Already processed")
        return
    # get date from link
    # example: https://github.com/adsblol/globe_history_2025/releases/download/v2025.01.09-planes-readsb-staging-0/v2025.01.09-planes-readsb-staging-0.tar.aa
    links_tfs = {link: tempfile.NamedTemporaryFile() for link in links}

    async def wget_chunked(link, tf):
        print(f"... Downloading {link}")
        async with aiohttp.ClientSession() as session:
            async with session.get(link) as response:
                while chunk := await response.content.read(16 * 1024):
                    tf.write(chunk)
        print(f"... Finished downloading {link}")

    await asyncio.gather(*[wget_chunked(link, tf) for link, tf in links_tfs.items()])

    # then, concatenate the files onto the first file and delete the rest,
    tf = links_tfs[links[0]]
    for link, tf_ in links_tfs.items():
        if link == links[0]:
            continue
        tf_.seek(0)
        tf.write(tf_.read())
        tf_.close()
        try:
            os.unlink(tf_.name)
        except Exception as e:
            print(f"Failed to delete {tf_.name}: {e}")

    # extract the file (it's a .tar) to /persist/adsblol/globe_history
    tf.seek(0)
    print(f"{L}: Extracting tar file")
    os.makedirs(path, exist_ok=True)
    # use asyncio subprocess to extract the tar file
    cmd = f"tar -xf {tf.name} -C {path}"
    proc = await asyncio.create_subprocess_shell(cmd)
    await proc.communicate()
    assert proc.returncode == 0
    print(f"{L}: Extraction complete")
    tf.close()
    try:
        os.unlink(tf.name)
    except Exception as e:
        print(f"Failed to delete {tf.name}: {e}")

    pathlib.Path(f"{path}/.done").touch()

async def main():
    SRCS = [
        "https://raw.githubusercontent.com/adsblol/globe_history_2025/refs/heads/main/PREFERRED_RELEASES.txt",
        "https://raw.githubusercontent.com/adsblol/globe_history_2024/refs/heads/main/PREFERRED_RELEASES.txt",
        "https://raw.githubusercontent.com/adsblol/globe_history_2023/refs/heads/main/PREFERRED_RELEASES.txt",
    ]

    LINKS = []
    for S in SRCS:
        print(f"Fetching content from: {S}")
        r = requests.get(S)
        links = r.text.split("\n")
        links = [link for link in links if link]
        LINKS.extend(links)
        print(f"Finished fetching content from: {S}")
    LINKS = LINKS[::-1]
    Semaphore = asyncio.Semaphore(4)

    async def _process_link(L):
        async with Semaphore:
            processed = False
            while not processed:
                try:
                    await process_link(L)
                    processed = True
                except Exception as e:
                    print(f"Failed to process {L}: {e}")
                    await asyncio.sleep(5)


    await asyncio.gather(*[_process_link(L) for L in LINKS])


if __name__ == "__main__":
    asyncio.run(main())
