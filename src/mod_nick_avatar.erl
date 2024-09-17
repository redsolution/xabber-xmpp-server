%%%-------------------------------------------------------------------
%%% File    : mod_nick_avatar.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Generate random nickname
%%% Created : 17 Sept. 2024 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2024   Redsolution OÜ
%%%
%%% This program is free software: you can redistribute it and/or
%%% modify it under the terms of the GNU Affero General Public License as
%%% published by the Free Software Foundation, either version 3 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------

-module(mod_nick_avatar).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1,
  depends/2, reload/3, mod_opt_type/1]).

%% API
-export([random_nick_and_avatar/1, get_avatar_file/1,
  merge_avatar/2, random_adjective/0]).

-include("logger.hrl").

%%----------------------
%% gen_mod callbacks.
%%----------------------
-spec start(binary(), gen_mod:opts()) -> ok.
start(Host, Opts) ->
  Path =  get_store_path(Host, Opts),
  Amount =  gen_mod:get_opt(amount, Opts),
  pre_generation(Path, Amount),
  ok.

-spec stop(binary()) -> ok.
stop(_Host) ->
  ok.

-spec reload(binary(), gen_mod:opts(), gen_mod:opts()) -> ok.
reload(Host, NewOpts, OldOpts) ->
  NewPath = get_store_path(Host, NewOpts),
  OldPath = get_store_path(Host, OldOpts),
  if NewPath /= OldPath ->
    Amount =  gen_mod:get_opt(amount, NewOpts),
    pre_generation(NewPath, Amount);
    true ->
      ok
  end.

mod_opt_type(store_path) ->
  fun iolist_to_binary/1;
mod_opt_type(amount) ->
  fun (I) when is_integer(I), I > 0 -> I end.

mod_options(_Host) ->
  [
    {store_path, <<"@HOME@/pre_avatars">>},
    {amount, 10}
  ].

depends(_, _) -> [].

%%----------------------
%% API.
%%----------------------

random_nick_and_avatar(Host) ->
  case get_avatar_file(Host) of
    {ok,FileName,Bin} ->
      {hd(binary:split(FileName,<<".">>)),{FileName, Bin}};
    _ ->
      {random_nick(), error}
  end.

random_adjective() ->
  random_list_item(new_adjectives()).

merge_avatar(Avatar1, Avatar2) ->
  eavatartools:merge_avatars(Avatar1, Avatar2).

get_avatar_file(Server) ->
  IsEnabled = gen_mod:is_loaded(Server, ?MODULE),
  get_avatar_file(IsEnabled, Server).


%%----------------------
%% Internal functions.
%%----------------------

get_avatar_file(true, Server) ->
  PreImages = get_store_path(Server),
  case file:list_dir(PreImages) of
    {ok, []} ->
      Amount = gen_mod:get_module_opt(Server, ?MODULE,amount),
      generate_files(PreImages, Amount, 0),
      error;
    {ok, Files} ->
      Nth =  rand:uniform(length(Files)),
      FileName= list_to_binary(lists:nth(Nth, Files)),
      File = <<PreImages/binary,"/", FileName/binary>>,
      case file:read_file(File) of
        {ok, Bin} ->
          spawn(replace_with_new(PreImages, File)),
          {ok, FileName, Bin};
        _ ->
          error
      end;
    _ ->
      error
  end;
get_avatar_file(_, _) ->
  error.

random_list_item(L) ->
  case lists:nth(rand:uniform(length(L)), L) of
    Item when is_list(Item) ->
      list_to_binary(Item);
    Item -> Item
  end.

random_nick() ->
  Animal = random_list_item(animals()),
  Adjective = random_list_item(adjectives()),
  Num = integer_to_binary(rand:uniform(99)),
  <<Adjective/binary," ",Animal/binary," ",Num/binary>>.

pre_generation(ImagePath, Amount) ->
  case file:list_dir(ImagePath) of
    {ok, Files} ->
      generate_files(ImagePath, Amount, length(Files));
    {error, enoent} ->
      case file:make_dir(ImagePath) of
        ok ->
          generate_files(ImagePath, Amount, 0);
        Err ->
          ?ERROR_MSG("make dir ~p; error: ~p",[ImagePath, Err])
      end;
    Err ->
      ?ERROR_MSG("list dir ~p; error: ~p",[ImagePath, Err])
  end.

generate_files(Path, Amount, CurrentAmount) ->
  NeedToGenerate = Amount - CurrentAmount,
  do_generate_files(Path, NeedToGenerate).

replace_with_new(StorePath, OldFile) ->
  ?DEBUG("Delete old file ~p and generate new",[OldFile]),
  fun() ->
    file:delete(OldFile),
    make_image(StorePath)
  end.

do_generate_files(_Path, 0) ->
  ok;
do_generate_files(Path, Count) when Count > 0 ->
  make_image(Path),
  do_generate_files(Path, Count - 1);
do_generate_files(_Path,_Count) ->
  ok.

make_image(Path) ->
  case eavatartools:make_avatar() of
    {ok, FileName, Data} ->
      do_store_file(filename:join(Path,FileName),
        Data, undefined, undefined);
    _ ->
      ?ERROR_MSG("Problem to generate image",[])
  end.

-spec do_store_file(file:filename_all(), binary(),
    integer() | undefined,
    integer() | undefined)
      -> ok | {error, term()}.
do_store_file(Path, Data, FileMode, DirMode) ->
  try
    ok = filelib:ensure_dir(Path),
    {ok, Io} = file:open(Path, [write, exclusive, raw]),
    Ok = file:write(Io, Data),
    ok = file:close(Io),
    if is_integer(FileMode) ->
      ok = file:change_mode(Path, FileMode);
      FileMode == undefined ->
        ok
    end,
    if is_integer(DirMode) ->
      RandDir = filename:dirname(Path),
      UserDir = filename:dirname(RandDir),
      ok = file:change_mode(RandDir, DirMode),
      ok = file:change_mode(UserDir, DirMode);
      DirMode == undefined ->
        ok
    end,
    ok = Ok % Raise an exception if file:write/2 failed.
  catch
    _:{badmatch, {error, Error}} ->
      {error, Error};
    _:Error ->
      {error, Error}
  end.

get_store_path(Host) ->
  Path = gen_mod:get_module_opt(Host, ?MODULE, store_path),
  get_store_path(Host,[{store_path, Path}]).

get_store_path(Host, Opts) ->
  Path = gen_mod:get_opt(store_path, Opts),
  Path1 = str:strip(Path, right, $/),
  {ok, [[Home]]} = init:get_argument(home),
  Path2 = misc:expand_keyword(<<"@HOME@">>, Path1, Home),
  Path3 = misc:expand_keyword(<<"@HOST@">>, Path2, Host),
  filename:absname(Path3).

new_adjectives() ->
  [
    "Accepting",
    "Accomplished",
    "Aggravated",
    "Agreeable",
    "Alone",
    "Amazed",
    "Ambivalent",
    "Amused",
    "Angry",
    "Animated",
    "Annoyed",
    "Anxious",
    "Apathetic",
    "Appreciative",
    "Ashamed",
    "Attractive",
    "Awake",
    "Awestruck",
    "Awful",
    "Bashful",
    "Beautiful",
    "Bewildered",
    "Bitter",
    "Bittersweet",
    "Blah",
    "Blank",
    "Blissful",
    "Bold",
    "Bored",
    "Bouncy",
    "Brave",
    "Calm",
    "Candid",
    "Cautious",
    "Cheerful",
    "Chilly",
    "Chipper",
    "Clever",
    "Cold",
    "Comfortable",
    "Complacent",
    "Composed",
    "Confident",
    "Confused",
    "Content",
    "Contented",
    "Cool",
    "Cranky",
    "Crappy",
    "Crazy",
    "Crushed",
    "Curious",
    "Cynical",
    "Delightful",
    "Depressed",
    "Determined",
    "Devious",
    "Dirty",
    "Disappointed",
    "Discontent",
    "Disenchanted",
    "Disgruntled",
    "Disgusted",
    "Distressed",
    "Ditzy",
    "Dorky",
    "Drained",
    "Dreadful",
    "Drunk",
    "Earnest",
    "Easy",
    "Easygoing",
    "Ecstatic",
    "Elated",
    "Encouraging",
    "Energetic",
    "Enraged",
    "Enthralled",
    "Envious",
    "Evenhanded",
    "Evil",
    "Exanimate",
    "Excited",
    "Exhausted",
    "Festive",
    "Flirty",
    "Free",
    "Fresh",
    "Frustrated",
    "Full",
    "Geeky",
    "Gentle",
    "Giddy",
    "Giggly",
    "Glad",
    "Gloomy",
    "Glum",
    "Good",
    "Grateful",
    "Groggy",
    "Grouchy",
    "Grumpy",
    "Guilty",
    "Happy",
    "Heavy",
    "High",
    "Hopeful",
    "Horrified",
    "Hostile",
    "Hot",
    "Hungry",
    "Hurtful",
    "Hyper",
    "Impressed",
    "Indescribable",
    "Indifferent",
    "Infuriated",
    "Intelligent",
    "Irate",
    "Irritated",
    "Jealous",
    "Jolly",
    "Joyful",
    "Jubilant",
    "Kind",
    "Lazy",
    "Lethargic",
    "Listless",
    "Lonely",
    "Loved",
    "Loving",
    "Mad",
    "Melancholy",
    "Mellow",
    "Merry",
    "Mischievous",
    "Miserable",
    "Moody",
    "Morose",
    "Mysterious",
    "Nasty",
    "Naughty",
    "Nerdy",
    "Nervous",
    "Neutral",
    "Nonpartisan",
    "Numb",
    "Obnoxious",
    "Okay",
    "Open",
    "Oppressive",
    "Optimistic",
    "Overbearing",
    "Passive",
    "Peaceful",
    "Pessimistic",
    "Pleased",
    "Pragmatic",
    "Predatory",
    "Proud",
    "Quixotic",
    "Quizzical",
    "Recumbent",
    "Refreshed",
    "Rejected",
    "Rejuvenated",
    "Relaxed",
    "Relieved",
    "Religious",
    "Resentful",
    "Reserved",
    "Respectful",
    "Restless",
    "Rushed",
    "Sad",
    "Sadistic",
    "Sarcastic",
    "Sardonic",
    "Satisfied",
    "Secretive",
    "Secular",
    "Selfish",
    "Serene",
    "Shocked",
    "Shy",
    "Sick",
    "Silly",
    "Sleepy",
    "Smart",
    "Sour",
    "Stressed",
    "Strong",
    "Supportive",
    "Surprised",
    "Sweet",
    "Sympathetic",
    "Tearful",
    "Tense",
    "Terrible",
    "Thankful",
    "Tired",
    "Touched",
    "Tranquil",
    "Ugly",
    "Uncomfortable",
    "Upbeat",
    "Vivacious",
    "Warm",
    "Weak",
    "Weird",
    "Wonderful"
  ].

adjectives() ->
  [
    "Adorable",
    "Amazing",
    "Brave",
    "Calm",
    "Careful",
    "Classical",
    "Clean",
    "Confident",
    "Delightful",
    "Eager",
    "Efficient",
    "Electronic",
    "Elegant",
    "Famous",
    "Fancy",
    "Fresh",
    "Futuristic",
    "Gentle",
    "Glamorous",
    "Handsome",
    "Happy",
    "Helpful",
    "Hungry",
    "Impressive",
    "Jolly",
    "Kind",
    "Lively",
    "Logical",
    "Magnificent",
    "Nice",
    "Ordinary",
    "Perfect",
    "Pleasant",
    "Practical",
    "Pragmatic",
    "Proud",
    "Rare",
    "Reasonable",
    "Rich",
    "Silly",
    "Snowy",
    "Sparkling",
    "Sunny",
    "Suspicious",
    "Technical",
    "Thankful",
    "Unusual",
    "Valuable",
    "Wicked",
    "Witty",
    "Wonderful",
    "Zealous"].

animals()->
  ["Abyssinian",
    "Affenpinscher",
    "African Bush Elephant",
    "African Civet",
    "African Clawed Frog",
    "African Forest Elephant",
    "African Palm Civet",
    "African Penguin",
    "African Tree Toad",
    "African Wild Dog",
    "Albatross",
    "Aldabra Giant Tortoise",
    "Alligator",
    "Angelfish",
    "Ant",
    "Anteater",
    "Antelope",
    "Arctic Fox",
    "Arctic Hare",
    "Arctic Wolf",
    "Armadillo",
    "Asian Elephant",
    "Asian Palm Civet",
    "Australian Mist",
    "Avocet",
    "Axolotl",
    "Aye Aye",
    "Baboon",
    "Bactrian Camel",
    "Badger",
    "Balinese",
    "Banded Palm Civet",
    "Bandicoot",
    "Barn Owl",
    "Barnacle",
    "Barracuda",
    "Basking Shark",
    "Bat",
    "Bear",
    "Beaver",
    "Bengal Tiger",
    "Bird",
    "Bison",
    "Black Bear",
    "Black Rhinoceros",
    "Bobcat",
    "Bornean Orang-utan",
    "Borneo Elephant",
    "Bottle Nosed Dolphin",
    "Brown Bear",
    "Budgerigar",
    "Buffalo",
    "Bumble Bee",
    "Burrowing Frog",
    "Butterfly",
    "Camel",
    "Capybara",
    "Caracal",
    "Cassowary",
    "Caterpillar",
    "Centipede",
    "Chameleon",
    "Cheetah",
    "Chinchilla",
    "Chinook",
    "Chinstrap Penguin",
    "Chipmunk",
    "Cichlid",
    "Clouded Leopard",
    "Coati",
    "Collared Peccary",
    "Common Buzzard",
    "Common Frog",
    "Coral",
    "Cougar",
    "Cow",
    "Coyote",
    "Crane",
    "Crested Penguin",
    "Crocodile",
    "Cross River Gorilla",
    "Curly Coated Retriever",
    "Cuttlefish",
    "Dachshund",
    "Dalmatian",
    "Deer",
    "Dolphin",
    "Dormouse",
    "Dragon",
    "Dragonfly",
    "Duck",
    "Dusky Dolphin",
    "Dwarf Fortress",
    "Eagle",
    "Earwig",
    "Echidna",
    "Egyptian Mau",
    "Electric Eel",
    "Elephant",
    "Elephant Seal",
    "Emperor Penguin",
    "Emperor Tamarin",
    "Emu",
    "Falcon",
    "Fennec Fox",
    "Flamingo",
    "Flying Squirrel",
    "Fox",
    "Frigatebird",
    "Frog",
    "Fur Seal",
    "Galapagos Penguin",
    "Galapagos Tortoise",
    "Geoffroys Tamarin",
    "Gerbil",
    "German Pinscher",
    "Giant Clam",
    "Gibbon",
    "Giraffe",
    "Goat",
    "Golden Lion Tamarin",
    "Goose",
    "Gopher",
    "Grasshopper",
    "Grey Reef Shark",
    "Grey Seal",
    "Grizzly Bear",
    "Guinea Fowl",
    "Guinea Pig",
    "Guppy",
    "Hammerhead Shark",
    "Hamster",
    "Hare",
    "Harrier",
    "Havanese",
    "Hedgehog",
    "Heron",
    "Howler Monkey",
    "Humboldt Penguin",
    "Hummingbird",
    "Humpback Whale",
    "Hyena",
    "Iguana",
    "Impala",
    "Jackal",
    "Jaguar",
    "Kakapo",
    "Kangaroo",
    "King Penguin",
    "Kingfisher",
    "Kiwi",
    "Koala",
    "Komodo Dragon",
    "Kudu",
    "Lemming",
    "Leopard",
    "Liger",
    "Lion",
    "Lionfish",
    "Little Penguin",
    "Lizard",
    "Lynx",
    "Macaroni Penguin",
    "Macaw",
    "Magellanic Penguin",
    "Magpie",
    "Malayan Civet",
    "Malayan Tiger",
    "Maltese",
    "Mandrill",
    "Manta Ray",
    "Markhor",
    "Masked Palm Civet",
    "Mastiff",
    "Mayfly",
    "Meerkat",
    "Millipede",
    "Monitor Lizard",
    "Monte Iberia Eleuth",
    "Moorhen",
    "Moose",
    "Moray Eel",
    "Moth",
    "Mountain Lion",
    "Mouse",
    "Newt",
    "Nightingale",
    "Ocelot",
    "Octopus",
    "Okapi",
    "Opossum",
    "Ostrich",
    "Otter",
    "Oyster",
    "Pademelon",
    "Panther",
    "Parrot",
    "Pekingese",
    "Pelican",
    "Penguin",
    "Pheasant",
    "Pied Tamarin",
    "Piranha",
    "Platypus",
    "Pointer",
    "Polar Bear",
    "Pond Skater",
    "Poodle",
    "Porcupine",
    "Possum",
    "Prawn",
    "Puffer Fish",
    "Puffin",
    "Pug",
    "Puma",
    "Purple Emperor",
    "Quail",
    "Quetzal",
    "Quokka",
    "Quoll",
    "Rabbit",
    "Radiated Tortoise",
    "Red Panda",
    "Red Wolf",
    "Red-handed Tamarin",
    "Reindeer",
    "Rhinoceros",
    "River Dolphin",
    "River Turtle",
    "Rock Hyrax",
    "Rockhopper Penguin",
    "Roseate Spoonbill",
    "Royal Penguin",
    "Sabre-Toothed Tiger",
    "Saint Bernard",
    "Salamander",
    "Sand Lizard",
    "Saola",
    "Sea Dragon",
    "Sea Otter",
    "Sea Slug",
    "Sea Squirt",
    "Sea Turtle",
    "Seahorse",
    "Seal",
    "Serval",
    "Sheep",
    "Shrimp",
    "Siberian Tiger",
    "Silver Dollar",
    "Sloth",
    "Slow Worm",
    "Snapping Turtle",
    "Snowshoe",
    "Snowy Owl",
    "Sparrow",
    "Spectacled Bear",
    "Sponge",
    "Squid",
    "Squirrel",
    "Stellers Sea Cow",
    "Stick Insect",
    "Stoat",
    "Striped Rocket Frog",
    "Sun Bear",
    "Swan",
    "Tapir",
    "Tarsier",
    "Tasmanian Devil",
    "Tawny Owl",
    "Tetra",
    "Thorny Devil",
    "Tibetan Mastiff",
    "Tiffany",
    "Tiger",
    "Tiger Salamander",
    "Tortoise",
    "Toucan",
    "Tropicbird",
    "Tuatara",
    "Uakari",
    "Uguisu",
    "Umbrellabird",
    "Vampire Bat",
    "Vulture",
    "Wallaby",
    "Walrus",
    "Warthog",
    "Water Buffalo",
    "Water Dragon",
    "Rhinoceros",
    "White Tiger",
    "Wildebeest",
    "Wolf",
    "Woodlouse",
    "Woodpecker",
    "Wrasse",
    "X-Ray Tetra",
    "Yak",
    "Yellow-Eyed Penguin",
    "Yorkshire Terrier",
    "Zebra",
    "Zebu",
    "Zonkey",
    "Zorse"].
