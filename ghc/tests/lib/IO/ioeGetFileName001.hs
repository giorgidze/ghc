-- !!! test ioeGetFileName

import IO

main = do
  h <- openFile "ioeGetFileName001.hs" ReadMode
  hSetBinaryMode h True
  hSeek h SeekFromEnd 0
  (hGetChar h >> return ()) `catch`
	\e -> if isEOFError e 
		then print (ioeGetFileName e)
		else putStrLn "failed."
